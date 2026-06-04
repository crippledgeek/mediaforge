#!/bin/sh
# Regression test: fetch() must NOT cache an HTTP error-page body as an archive.
#
# Bug: `curl -L -sS -o file url` (no -f) writes the server's HTML error body to
# the output file AND exits 0 on HTTP >=400. fetch() then treats the poisoned
# error page as a valid cached tarball, and every later run skips re-download
# (file exists) and fails at extraction. A transient mirror 502 permanently
# poisons the cache.
#
# Fix: `curl -fL ...` makes curl exit non-zero on HTTP >=400, so the retry loop
# removes the partial file and ultimately die()s with nothing cached.
#
# This test stands up a local server that always replies 502 and asserts:
#   (a) fetch returns non-zero (it die()d), and
#   (b) no archive file is left in DISTDIR (the load-bearing poisoned-cache guard).

set -u

# python3 is a documented optional dependency — skip if absent.
command -v python3 >/dev/null 2>&1 || { echo 'SKIP (no python3)'; exit 0; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

DISTDIR=$(mktemp -d)
PORT_FILE=$(mktemp)
SRV_PID=''

# Single-quote so the variables expand at trap time, not now (shellcheck-clean,
# matches the trap idiom used by the other tests).
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$DISTDIR"; rm -f "$PORT_FILE"' EXIT INT TERM

# Tiny HTTP server: bind 127.0.0.1 on an ephemeral port, answer every GET with
# 502 + an HTML body, and write the chosen port to PORT_FILE so the shell can
# read it back. Runs in the background; trap-killed on EXIT.
python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<html><body><h1>502 Bad Gateway</h1></body></html>"
        self.send_response(502)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
    f.flush()
srv.serve_forever()
' "$PORT_FILE" &
SRV_PID=$!

# Wait (briefly) for the server to publish its port.
_i=0
PORT=''
while [ "$_i" -lt 50 ]; do
  PORT=$(cat "$PORT_FILE" 2>/dev/null)
  [ -n "$PORT" ] && break
  sleep 0.1
  _i=$((_i + 1))
done

if [ -z "$PORT" ]; then
  echo 'FAIL (server did not start)'
  exit 1
fi

# Source utils (log/warn/die) and the unit under test (download.sh / fetch).
. "$ROOT/lib/utils.sh"
. "$ROOT/lib/download.sh"
export DISTDIR

_archive="gmp-6.3.0.tar.xz"

# fetch() reads PKG_URL / PKG_FILENAME / PKG_DIRNAME via `${N:-$PKG_*}` defaults.
# Under `set -u` an unset PKG_* would abort fetch before it ever downloads (a
# false pass). Recipes always run with these defined, so define them here to
# mirror the real environment. PKG_DIRNAME stays empty (fetch auto-derives it).
PKG_URL=''
PKG_FILENAME=''
PKG_DIRNAME=''
export PKG_URL PKG_FILENAME PKG_DIRNAME

# die() calls exit 1, so run fetch in a subshell to capture the failure code.
( fetch "http://127.0.0.1:$PORT/$_archive" ) >/dev/null 2>&1
_rc=$?

_fail=false

# Assertion (a): fetch must have failed (die -> non-zero).
if [ "$_rc" -eq 0 ]; then
  echo "FAIL: fetch returned 0 on HTTP 502 (expected non-zero die)"
  _fail=true
fi

# Assertion (b) [load-bearing]: no error body cached as the archive.
if [ -f "$DISTDIR/$_archive" ]; then
  echo "FAIL: HTTP error body was cached as $_archive ($(wc -c < "$DISTDIR/$_archive") bytes)"
  _fail=true
fi

if [ "$_fail" = true ]; then
  exit 1
fi

echo 'PASS'
exit 0
