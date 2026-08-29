#!/bin/sh
# LCEVC single-pass static-link regression test.
#
# Reproduces the downstream rdlp failure: a static consumer linking FFmpeg's
# (or LCEVC's) pkg-config output in a single left-to-right pass cannot resolve
# the circular references among V-Nova's 8 split LCEVC archives, yielding
# undefined LCEVC_* symbols.
#
# The fix (merge the 8 archives into one liblcevc_dec.a + rewrite the .pc to a
# single -llcevc_dec) makes the single-pass link resolve cleanly, because GNU
# ld re-scans members WITHIN a single archive until no new symbol is satisfied.
#
# Usage:
#   tests/lcevc-static-link.sh [PREFIX] [PC_NAME...]
#     PREFIX   prefix containing lib/pkgconfig (default: $TOPDIR/workspace)
#     PC_NAME  pkg-config module(s) to link (default: lcevc_dec)
#
# Exit 0 = links clean. Exit 1 = link failed (regression). Exit 2 = skipped
# (LCEVC not present in the prefix — e.g. default build with lcevc opt-out).
set -eu

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${1:-"$_here/../workspace"}
shift 2>/dev/null || true
PC_MODULES=${*:-lcevc_dec}

PREFIX=$(CDPATH='' cd -- "$PREFIX" && pwd)
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/$(gcc -dumpmachine 2>/dev/null)/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_PATH

# Skip cleanly when LCEVC is not installed (opt-out build) — its absence is a
# valid configuration, not a test failure.
if ! pkg-config --exists lcevc_dec 2>/dev/null; then
  echo "SKIP: lcevc_dec not found under $PREFIX (LCEVC opt-out build)"
  exit 2
fi

# PC_MODULES is intentionally unquoted: it may hold several pkg-config module
# names that must word-split into separate arguments.
# shellcheck disable=SC2086
_cflags=$(pkg-config --cflags $PC_MODULES)
# shellcheck disable=SC2086
_libs=$(pkg-config --static --libs $PC_MODULES)
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_here/lib-assert.sh"

_probe="$_here/lcevc-link/link_probe.cpp"
_cxx=${CXX:-c++}
_out=$(mktemp -d)
trap 'rm -rf "$_out"' EXIT
_cleanup_on_signal

echo "PREFIX:      $PREFIX"
echo "modules:     $PC_MODULES"
echo "compiler:    $_cxx"
echo "static libs: $_libs"
echo

# Single-pass link: NO -Wl,--start-group. This is the whole point — it mimics a
# downstream consumer's link and fails iff the circular archives are unmerged.
# shellcheck disable=SC2086
if "$_cxx" "$_probe" $_cflags -o "$_out/probe" $_libs 2>"$_out/err"; then
  _pass single-pass-static-link-resolves
  exit 0
else
  _bad single-pass-static-link-resolves \
    "$(_evidence 10 'undefined|cannot find|library not found' < "$_out/err")"
  exit 1
fi
