# shellcheck shell=sh
# A local HTTP origin, for the tests that drive fetch() without the network.
#
# Two files wanted one. tests/fetch-fail-no-cache.sh stood one up to answer 502
# to everything; tests/download-retry-verify.sh (GH-70) stood up a second to
# serve a scripted sequence of 200 bodies and count requests. The second was
# written as a sibling of the first -- the same bind-to-an-ephemeral-port, the
# same publish-the-port-to-a-file, the same fifty-tenths-of-a-second wait for
# it -- and near-identical copies do not stay identical. Whichever one grows a
# timeout, a header, an IPv6 bind or a retry, the other does not, and the two
# tests then disagree about what an origin is while both still pass.
#
# The SCRIPTED SEQUENCE is what lets one origin serve both. Each line of
# SEQFILE is `<status> <path-to-body-file>`; the Nth request takes the Nth
# line, and the last line repeats forever. So "always 502" is a one-line
# script, "fail then succeed" is a two-line one, and neither test needs its own
# server. Every request appends a line to COUNTFILE, which is how a test
# asserts how MANY requests were made rather than inferring it from an exit
# status -- "retried exactly once" is not a claim an exit status can carry.
#
# Both files are re-read per request rather than held in memory, so a test can
# rewrite the script between runs and reuse one long-lived origin.
#
# Content-Type is application/octet-stream on every response, including the
# error bodies. Nothing under test reads it: `curl -f` keys on the status line,
# and fetch() decides by digest. tests/fetch-fail-no-cache.sh sent text/html
# before this was shared; the change is deliberate and its assertions are
# unaffected.
#
# A MALFORMED script is diagnosable but points the wrong way, so it is worth
# knowing here: an empty SEQFILE indexes an empty list and a line with no space
# fails to split, both of which kill the handler and close the connection. The
# caller then reports "Failed to download ... after 3 attempts" -- a
# network-shaped message for a fixture-shaped bug. socketserver prints the
# traceback, so it is recoverable from a test that captures the origin's
# stderr; a test that discards it sees only the download failure.
#
# The caller keeps its own EXIT trap and kills $ORIGIN_PID from it. POSIX
# `trap` has no append form, so a trap registered here would silently replace
# the caller's -- the same reason tests/lib-assert.sh registers only the signal
# half and tests/lib-scratch.sh registers none.

# _origin_start SEQFILE COUNTFILE PORTFILE
# Start the origin in the background and set $ORIGIN_PID. The port it bound is
# published to PORTFILE; read it back with _origin_port, which is a separate
# call because the server cannot write the file until after it has bound.
_origin_start() {
  python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

seq_file, count_file, port_file = sys.argv[1:4]

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(seq_file) as f:
            seq = [l.strip() for l in f if l.strip()]
        with open(count_file) as f:
            n = sum(1 for l in f if l.strip())
        with open(count_file, "a") as f:
            f.write("x\n")
        status, path = seq[min(n, len(seq) - 1)].split(" ", 1)
        body = open(path, "rb").read()
        self.send_response(int(status))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
    f.flush()
srv.serve_forever()
' "$1" "$2" "$3" &
  ORIGIN_PID=$!
}

# _origin_stop
# Kill the origin, if one is running. Safe to call when it never started, which
# is exactly what a caller's EXIT trap needs -- the trap is registered before
# the server is, so it fires on a failure between the two.
#
# The stop half lives HERE rather than in each caller's trap string because a
# caller writing `kill "$ORIGIN_PID"` itself has to know that the variable may
# be unset, that kill's failure must be swallowed, and that the trap runs on
# paths where no server exists. Three things to remember, in a trap, is how the
# copies this library replaced came to differ.
_origin_stop() {
  [ -n "${ORIGIN_PID:-}" ] && kill "$ORIGIN_PID" 2>/dev/null
  ORIGIN_PID=''
  return 0
}

# _origin_requests COUNTFILE
# How many requests the origin has served. Kept here for the same reason the
# kill is: tests/download-retry-verify.sh computes it inside its runner and
# tests/fetch-fail-no-cache.sh needs it to prove the fixture was reached, and
# two copies of `wc -l | tr -d ' '` is how a counter's shape starts to differ.
_origin_requests() {
  wc -l < "$1" | tr -d ' '
}

# _origin_port PORTFILE
# Print the port the origin bound, or return non-zero after ~5 seconds. The
# caller reports the failure: a test that cannot reach its fixture has not
# measured anything, and must say so rather than assert against nothing.
_origin_port() {
  _op_i=0
  _op_port=''
  while [ "$_op_i" -lt 50 ]; do
    _op_port=$(cat "$1" 2>/dev/null)
    [ -n "$_op_port" ] && break
    sleep 0.1
    _op_i=$((_op_i + 1))
  done
  [ -n "$_op_port" ] || return 1
  printf '%s' "$_op_port"
}
