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

# lib-assert is sourced HERE rather than beside the other libraries below,
# because the trap a few lines down needs _cleanup_on_signal to exist: a helper
# defined after the handler it protects leaves the window between them unguarded.
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
# shellcheck source=tests/lib-origin.sh
. "$ROOT/tests/lib-origin.sh"
# shellcheck source=tests/lib-fetch.sh
. "$ROOT/tests/lib-fetch.sh"

DISTDIR=$(mktemp -d)
PORT_FILE=$(mktemp)
COUNT_FILE=$(mktemp)
SEQ_FILE=$(mktemp)
BODY_FILE=$(mktemp)

# Single-quote so the variables expand at trap time, not now (shellcheck-clean,
# matches the trap idiom used by the other tests). _origin_stop is the shared
# origin's own kill, which is safe before the server exists.
trap '_origin_stop; rm -rf "$DISTDIR"; rm -f "$PORT_FILE" "$COUNT_FILE" "$SEQ_FILE" "$BODY_FILE"' EXIT
_cleanup_on_signal

# The origin, from tests/lib-origin.sh: one script line, so every request gets
# the same 502 and an HTML body. The shared origin replaced a copy of itself
# that lived here -- see that file's head for why one server serves both this
# test and tests/download-retry-verify.sh.
printf '<html><body><h1>502 Bad Gateway</h1></body></html>' > "$BODY_FILE"
printf '502 %s\n' "$BODY_FILE" > "$SEQ_FILE"
_origin_start "$SEQ_FILE" "$COUNT_FILE" "$PORT_FILE"
if ! PORT=$(_origin_port "$PORT_FILE"); then
  printf 'ERROR: the fixture origin did not start\n' >&2
  exit 1
fi

# The unit under test, from tests/lib-fetch.sh: lib/download.sh plus the
# recipe state fetch() reads. Shared with tests/download-retry-verify.sh.
_load_fetch "$ROOT" "$DISTDIR"
_fail=0

_archive="gmp-6.3.0.tar.xz"

# die() calls exit 1, so run fetch in a subshell to capture the failure code.
( fetch "http://127.0.0.1:$PORT/$_archive" ) >/dev/null 2>&1
_rc=$?

# Both halves in ONE assertion, as this file has always reported them: (a) fetch
# failed, and (b) [load-bearing] it cached no error body as the archive. Either
# alone is satisfiable by the wrong code -- a fetch that fails but still writes
# the 502 body leaves the next run resolving a poisoned cache hit.
_wrong=''
if [ "$_rc" -eq 0 ]; then
  _wrong="$_wrong fetch returned 0 on HTTP 502 (expected a non-zero die);"
fi
if [ -f "$DISTDIR/$_archive" ]; then
  _wrong="$_wrong the error body was cached as $_archive"
  _wrong="$_wrong ($(wc -c < "$DISTDIR/$_archive") bytes);"
fi

# ...and (c) the origin was actually REACHED. Connection-refused satisfies both
# halves above exactly as a 502 does, so without this the claim passes against a
# fixture that never started or died early -- measured: killing the origin after
# the port is read leaves this test green having never seen a 502, which is the
# thing it exists to guard. download_file makes three attempts before it dies.
_reqs=$(_origin_requests "$COUNT_FILE")
if [ "$_reqs" -ne 3 ]; then
  _wrong="$_wrong the origin served $_reqs request(s), expected 3 --"
  _wrong="$_wrong the 502 path may not have been exercised at all;"
fi

_verdict failed-fetch-caches-no-error-body "$_wrong"

exit "$_fail"
