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
# Uses --dry-run, which logs the accumulated FFMPEG_CONFIGURE_OPTS via the
# "Would configure FFmpeg with:" line (mediaforge.sh cmd_build's DRY_RUN
# guard) rather than running FFmpeg's real configure. We assert against that
# line specifically (not the whole log, which also mentions lcevc elsewhere).
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"
# shellcheck source=tests/lib-scratch.sh
. "$_root/tests/lib-scratch.sh"
_scratch_init "$_root"
# The non-Linux path below exits early, so the cleanup is a trap rather than a
# call at the tail.
trap '_scratch_cleanup' EXIT

# Extract the accumulated FFmpeg configure-opts line from a dry-run.
_configure_line() {
  _mf build --dry-run "$@" 2>&1 | grep -- 'Would configure FFmpeg with:' || true
}

# 1) default build: flag absent
_default=$(_configure_line)
if [ -z "$_default" ]; then
  _bad default-build-omits-lcevc-flag "the dry-run emitted no configure line — cannot assert"
elif printf '%s\n' "$_default" | grep -q -- '--enable-liblcevc-dec'; then
  _bad default-build-omits-lcevc-flag \
    "--enable-liblcevc-dec was passed to FFmpeg; lcevc is opt-in"
else
  _pass default-build-omits-lcevc-flag
fi

# 2) --enable=lcevc: flag present.
#
# Linux-only, and skipped rather than failed elsewhere. recipes/other/lcevc.sh
# sets PKG_LINUX_ONLY=true (added in 829b927 alongside the archive merge, which
# uses GNU ar/ranlib), and check_guards (lib/framework.sh) returns 1 for
# that on a non-Linux host BEFORE the force-enable branch can matter — so
# --enable=lcevc legitimately emits nothing on macOS. Asserting unconditionally
# would make `tests/run.sh` Linux-only for a project that supports macOS
# throughout; assertion 1 above is platform-independent and still runs.
if [ "$(uname -s)" != "Linux" ]; then
  echo "SKIP: --enable=lcevc opt-in assertion (lcevc is PKG_LINUX_ONLY; host is $(uname -s))"
  exit "$_fail"
fi

_optin=$(_configure_line --enable=lcevc)
if [ -z "$_optin" ]; then
  _bad optin-lcevc-passes-flag "the dry-run emitted no configure line — cannot assert"
elif printf '%s\n' "$_optin" | grep -q -- '--enable-liblcevc-dec'; then
  _pass optin-lcevc-passes-flag
else
  _bad optin-lcevc-passes-flag "--enable=lcevc did not pass --enable-liblcevc-dec"
fi

exit "$_fail"
