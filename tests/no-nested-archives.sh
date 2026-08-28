#!/bin/sh
# Guard: no recipe leaves a static archive in a lib/ SUBDIR.
#
# mediaforge's installer (lib/install.sh) copies only $PREFIX/lib/*.a (flat) into
# the installed prefix. A .a in a nested lib/<name>/ subdir is therefore never
# shipped — either a downstream-breaking bug (oapv: the only copy was nested) or
# a redundant duplicate (xeve/xevd: a flat copy exists, the nested one lingered).
# Either way the workspace should carry no nested archives.
#
# Usage: tests/no-nested-archives.sh [PREFIX]   (default: $TOPDIR/workspace)
# Exit 0 = clean, 1 = nested archive found, 2 = skipped (not built).
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_here/lib-assert.sh"

PREFIX=${1:-"$_here/../workspace"}
if [ ! -d "$PREFIX/lib" ]; then
  echo "SKIP: $PREFIX/lib not present (nothing built here)"; exit 2
fi
PREFIX=$(CDPATH='' cd -- "$PREFIX" && pwd)

_nested=$(find "$PREFIX/lib" -mindepth 2 -name '*.a' 2>/dev/null)
if [ -n "$_nested" ]; then
  _bad no-archive-nested-in-lib-subdir \
    "installer ships only lib/*.a flat, but found: $_nested"
  exit 1
fi
_pass no-archive-nested-in-lib-subdir
exit 0
