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

_run "unknown pkg, no suggestion" "Run '.*--list-pkgs'" \
  ./mediaforge.sh build --disable=zzznonexistent --dry-run --yes

exit "$_fail"
