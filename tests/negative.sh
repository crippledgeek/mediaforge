#!/bin/sh
# Negative tests: invalid input must fail with an actionable message.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_run() {
  _desc=$1; shift
  _expect=$1; shift
  _output=$("$@" 2>&1) && _rc=0 || _rc=$?
  if [ "$_rc" = "0" ]; then
    printf 'FAIL [%s]: expected non-zero exit, got 0\n' "$_desc" >&2
    _fail=1
    return
  fi
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    printf 'FAIL [%s]: stderr did not contain "%s"\n' "$_desc" "$_expect" >&2
    printf '  got: %s\n' "$_output" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

_run_log() {
  _desc=$1; shift
  _expect=$1; shift
  _output=$("$@" 2>&1) || true
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    printf 'FAIL [%s]: output did not contain "%s"\n' "$_desc" "$_expect" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

_run "unknown pkg with suggestion" "Did you mean: openssl" \
  ./mediaforge.sh build --disable=openss --dry-run --yes

_run_log "force-enable does not bypass nonfree guard" "Skipping srt (requires --nonfree)" \
  ./mediaforge.sh build --enable=srt --dry-run --yes

_run "--menu --yes is rejected" "mutually exclusive" \
  ./mediaforge.sh build --menu --yes

_run "unknown pkg, no suggestion" "Run '.*--list-pkgs'" \
  ./mediaforge.sh build --disable=zzznonexistent --dry-run --yes

# Regression: a mutex-disabled recipe that was previously stamped must NOT
# leak its --enable flag (would collide with the chosen backend -> FFmpeg die).
# Simulate by stamping gnutls then selecting openssl; only one TLS flag may appear.
_stampdir="workspace/.stamps"
mkdir -p "$_stampdir"
# Derive the stamp name from the version the recipe actually declares, so a
# future gnutls version bump keeps this test exercising the real leak path
# instead of silently becoming vacuous against a stale hardcoded filename.
_gv=$(sh -c '. recipes/crypto/gnutls.sh 2>/dev/null; printf "%s" "$PKG_VERSION"')
_stampfile="$_stampdir/gnutls-$_gv"
# Always remove the temporary stamp, even if the build aborts early under set -e.
# Single-quote so $_stampfile is expanded at trap time, not now (shellcheck-clean).
trap 'rm -f "$_stampfile"' EXIT
: > "$_stampfile"
_out=$(./mediaforge.sh build --tls=openssl --dry-run --yes 2>&1) || true
rm -f "$_stampfile"
if printf '%s' "$_out" | grep -q 'enable-gnutls'; then
  printf 'FAIL [stamp-leak]: --enable-gnutls leaked while --tls=openssl\n' >&2
  _fail=1
else
  printf 'PASS [stamp-leak: disabled backend flag suppressed]\n'
fi

exit "$_fail"
