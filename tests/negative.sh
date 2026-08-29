#!/bin/sh
# Negative tests: invalid input must fail with an actionable message.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
# shellcheck source=tests/lib-scratch.sh
. "$ROOT/tests/lib-scratch.sh"
_scratch_init "$ROOT"

# _run <assertion-name> <expected-text> <command...>: the command must exit
# non-zero AND say the expected thing. _run_log is the same without the exit
# requirement, for a build that legitimately succeeds while logging a skip.
_run() {
  _name=$1; shift
  _expect=$1; shift
  _output=$("$@" 2>&1) && _rc=0 || _rc=$?
  if [ "$_rc" = "0" ]; then
    _bad "$_name" "expected a non-zero exit, got 0"
    return
  fi
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    _bad "$_name" "output did not contain \"$_expect\"; got: $_output"
    return
  fi
  _pass "$_name"
}

_run_log() {
  _name=$1; shift
  _expect=$1; shift
  _output=$("$@" 2>&1) || true
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    _bad "$_name" "output did not contain \"$_expect\"; got: $_output"
    return
  fi
  _pass "$_name"
}

_run unknown-pkg-suggests-nearest "Did you mean: openssl" \
  _mf build --disable=openss --dry-run --yes

_run_log force-enable-does-not-bypass-nonfree-guard "Skipping srt (requires --nonfree)" \
  _mf build --enable=srt --dry-run --yes

_run menu-and-yes-are-mutually-exclusive "mutually exclusive" \
  _mf build --menu --yes

_run unknown-pkg-without-suggestion-points-at-list-pkgs "Run '.*--list-pkgs'" \
  _mf build --disable=zzznonexistent --dry-run --yes

_run spirv-bogus-value-rejected "Invalid --spirv" \
  _mf build --spirv=bogus --dry-run --yes

# Regression: a mutex-disabled recipe that was previously stamped must NOT
# leak its --enable flag (would collide with the chosen backend -> FFmpeg die).
# Simulate by stamping gnutls then selecting openssl; only one TLS flag may appear.
# The stamps go in the scratch TOPDIR mediaforge is now run from, not in the
# repo's own workspace/ (#55). This file is the one that WRITES to the prefix
# rather than merely reading it: `mkdir -p workspace/.stamps` created that
# directory in a repo that had never been built, and each stamp below sat in a
# real build tree for the length of one dry run.
_stampdir="$_MF_SCRATCH/workspace/.stamps"
mkdir -p "$_stampdir"
# Derive the stamp name from the version the recipe actually declares, so a
# future gnutls version bump keeps this test exercising the real leak path
# instead of silently becoming vacuous against a stale hardcoded filename.
_gv=$(sh -c '. recipes/crypto/gnutls.sh 2>/dev/null; printf "%s" "$PKG_VERSION"')
_stampfile="$_stampdir/gnutls-$_gv"
# Derive glslang stamp name the same way (version-resilient) so the spirv
# mutex stamp-leak check below stays meaningful across glslang version bumps.
_gv=$(sh -c '. recipes/hwaccel/glslang.sh 2>/dev/null; printf "%s" "$PKG_VERSION"')
_glslang_stampfile="$_stampdir/glslang-$_gv"
# Derive the xavs2 stamp name the same way for the GPL stamp-leak check below.
_xv=$(sh -c '. recipes/video/xavs2.sh 2>/dev/null; printf "%s" "$PKG_VERSION"')
_xavs2_stampfile="$_stampdir/xavs2-$_xv"
# Clean up on exit even if a build aborts early under set -e. One handler, not
# four: `trap ... EXIT` has no append form in POSIX sh, so a second registration
# would replace this one rather than add to it. Removing the scratch TOPDIR is
# now the whole cleanup — every stamp this file plants lives inside it, which is
# the point of the change. The per-assertion `rm -f` calls below stay, because
# they sequence the assertions rather than clean up after them: each one must
# not see the stamp the previous one planted.
trap '_scratch_cleanup' EXIT
: > "$_stampfile"
_out=$(_mf build --tls=openssl --dry-run --yes 2>&1) || true
rm -f "$_stampfile"
if printf '%s' "$_out" | grep -q 'enable-gnutls'; then
  _bad stamped-tls-loser-flag-suppressed "--enable-gnutls leaked while --tls=openssl"
else
  _pass stamped-tls-loser-flag-suppressed
fi

# glslang stamped + --spirv=shaderc must NOT leak --enable-libglslang. The two
# SPIR-V flags are mutually exclusive — a leak would collide with
# --enable-libshaderc and make FFmpeg's configure die.
: > "$_glslang_stampfile"
_out=$(_mf build --spirv=shaderc --dry-run --yes 2>&1) || true
rm -f "$_glslang_stampfile"
if printf '%s' "$_out" | grep -q 'enable-libglslang'; then
  _bad stamped-spirv-loser-flag-suppressed "--enable-libglslang leaked while --spirv=shaderc"
else
  _pass stamped-spirv-loser-flag-suppressed
fi

# Regression: a GPL recipe built in a prior --enable-gpl run (stamp present)
# must NOT leak its --enable flag into a later FREE build — FFmpeg's configure
# rejects e.g. --enable-libx264 without --enable-gpl.
: > "$_xavs2_stampfile"
_out=$(_mf build --dry-run --yes 2>&1) || true
rm -f "$_xavs2_stampfile"
if printf '%s' "$_out" | grep -q 'enable-libxavs2'; then
  _bad stamped-gpl-flag-suppressed-in-free-build "--enable-libxavs2 leaked into a free build"
else
  _pass stamped-gpl-flag-suppressed-in-free-build
fi

exit "$_fail"
