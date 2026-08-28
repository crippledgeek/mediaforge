#!/bin/sh
# Pins that dav1d is built as a LIBRARY ONLY.
#
# FFmpeg links libdav1d.a and never invokes dav1d's CLI, but the recipe built
# and installed one anyway -- a ~3MB $PREFIX/bin/dav1d that nothing in this
# project or downstream of it uses.
#
# The reason this is worth a test rather than a comment is the second effect.
# dav1d's tools include the SYSTEM /usr/include/xxhash.h, whose XXH3_*_sse2
# helpers are __attribute__((always_inline)); below -O2 gcc declines to inline
# them and hard-errors with "inlining failed in call to always_inline". So with
# the tools on, dav1d is the one recipe in the tree that cannot be compiled for
# debugging -- and the failure arrives as a wall of inliner errors pointing at a
# system header, which reads like a broken toolchain rather than a recipe
# setting. Measured: the library alone configures and builds clean at -Og with
# the tools off, and at release it is byte-for-byte the same 3.4MB archive.
#
# Anyone re-enabling the tools to get the CLI back should read that first.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_recipe=recipes/video/dav1d.sh

# No separate "the recipe exists" assertion: it would pass on the merge base,
# where the recipe also exists, and tests/oracle-baseline.sh counts any pass on
# the base as proof the file is not detecting its change. The floor is implicit
# instead -- a missing or renamed recipe yields an empty body, which matches
# none of the patterns below, so every claim reports FAIL rather than passing
# vacuously.
_body=$(cat "$_recipe" 2>/dev/null || printf '')

case "$_body" in
  *-Denable_tools=false*) _pass dav1d-tools-disabled ;;
  *) _bad dav1d-tools-disabled "recipe does not pass -Denable_tools=false" ;;
esac

case "$_body" in
  *-Denable_tests=false*) _pass dav1d-tests-disabled ;;
  *) _bad dav1d-tests-disabled "recipe does not pass -Denable_tests=false" ;;
esac

# The reason has to travel with the setting. A bare -Denable_tools=false reads
# as a size optimization, and the next person tidying the recipe has no way to
# know it is also what keeps the recipe buildable below -O2.
case "$_body" in
  *always_inline*) _pass dav1d-rationale-recorded ;;
  *) _bad dav1d-rationale-recorded "the always_inline reason is not recorded at the setting" ;;
esac

printf 'DONE: dav1d-library-only\n'
exit "$_fail"
