#!/bin/sh
# LCEVC opt-in regression test.
#
# LCEVC is patent-encumbered, decode-only, and needs post-build archive merging
# for downstream static linking, so it is default-OFF and only built/enabled via
# --enable=lcevc. This guards two behaviours:
#
#   1. A default build must NOT pass --enable-liblcevc-dec to FFmpeg — even on a
#      workspace where lcevc was built by a prior run (a stamp exists). This
#      exercises the lib/framework.sh fix that treats a non-force-enabled
#      PKG_DISABLED recipe as a policy exclusion (no flag re-accumulation).
#   2. --enable=lcevc must pass --enable-liblcevc-dec.
#
# Uses --dry-run, which prints the assembled `$ ./configure ...` line. We assert
# against that line specifically (not the whole log, which also mentions lcevc).
# NB: dry-run currently runs FFmpeg's configure for real; an unrelated configure
# failure (e.g. a missing optional dep) is tolerated — the configure line is
# logged before configure runs, so the assertion still holds. Hence no `set -e`.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0

# Extract the assembled FFmpeg configure command line from a dry-run.
_configure_line() {
  ./mediaforge.sh build --dry-run "$@" 2>&1 | grep -- '\$ ./configure' || true
}

# 1) default build: flag absent
_default=$(_configure_line)
if [ -z "$_default" ]; then
  echo "FAIL: default dry-run emitted no configure line — cannot assert"
  _fail=1
elif printf '%s\n' "$_default" | grep -q -- '--enable-liblcevc-dec'; then
  echo "FAIL: default build passed --enable-liblcevc-dec to FFmpeg (should be opt-in)"
  _fail=1
else
  echo "PASS: default build omits --enable-liblcevc-dec"
fi

# 2) --enable=lcevc: flag present
_optin=$(_configure_line --enable=lcevc)
if [ -z "$_optin" ]; then
  echo "FAIL: --enable=lcevc dry-run emitted no configure line — cannot assert"
  _fail=1
elif printf '%s\n' "$_optin" | grep -q -- '--enable-liblcevc-dec'; then
  echo "PASS: --enable=lcevc passes --enable-liblcevc-dec to FFmpeg"
else
  echo "FAIL: --enable=lcevc did not pass --enable-liblcevc-dec"
  _fail=1
fi

exit "$_fail"
