#!/bin/sh
# Pins that cmake is CONFIGURED in exactly one place (mf_cmake, lib/framework.sh)
# and that the build type has exactly one spelling (PKG_CMAKE_BUILD_TYPE).
#
# Before this, nineteen recipes each wrote their own `run cmake` line and
# fourteen of them spelled the build type inline -- some in PKG_CMAKE_FLAGS,
# some as a continuation line, some mid-invocation. Nothing enforced agreement,
# and ten recipes set no build type at all without that being a decision anyone
# had made. The cost is not the duplication itself: it is that the build type is
# the knob a debug mode has to turn, and turning it in nineteen places is
# nineteen chances to miss one -- silently, since a recipe that keeps building
# Release while the rest go debug produces a mixed tree that still links.
#
# This is the same shape as tests/no-nested-archives.sh's fetch invariant: the
# rule is "route through the one entry point", and a grep is what enforces it.
#
# `cmake --build` and `cmake --install` are NOT configuration -- they drive an
# already-configured tree and carry no flags this file is about -- so they are
# excluded rather than counted as offenders.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# THE FLOOR. Every assertion below is a "grep finds nothing" claim, and an empty
# recipes/ would satisfy all of them having verified nothing. Assert first that
# the population actually exists, so a pass means "checked and clean" rather
# than "there was nothing to check".
_sites=$(grep -rlE '(^|[^_[:alnum:]])mf_cmake ' recipes/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$_sites" -ge 10 ]; then
  _pass cmake-recipes-present-to-check
else
  _bad cmake-recipes-present-to-check "only $_sites recipe(s) call mf_cmake; expected >=10"
fi

# 1. Nothing configures cmake outside the helper.
# `--` before the pattern: it starts with dashes, and without the terminator
# grep reads it as options. Escaping them instead ("\-\-build") is what a first
# draft does, and GNU grep warns "stray \ before -" on every invocation.
_direct=$(grep -rn 'run cmake' recipes/ 2>/dev/null | grep -vE -- '--build|--install' || true)
if [ -z "$_direct" ]; then
  _pass no-recipe-configures-cmake-directly
else
  _bad no-recipe-configures-cmake-directly "$(printf '%s' "$_direct" | head -3)"
fi

# 2. The build type is named one way. An inline -DCMAKE_BUILD_TYPE would be
#    invisible to the single knob and would silently outrank it, since cmake
#    takes the last -D for a given cache variable.
_inline=$(grep -rn 'DCMAKE_BUILD_TYPE' recipes/ 2>/dev/null || true)
if [ -z "$_inline" ]; then
  _pass build-type-has-one-spelling
else
  _bad build-type-has-one-spelling "$(printf '%s' "$_inline" | head -3)"
fi

# 3. The helper supplies the install prefix, which is the argument every call
#    site used to repeat and the one a recipe silently omitting would install
#    into /usr/local.
#    Scoped to mf_cmake's OWN body, not to the file. lib/framework.sh already
#    contained CMAKE_INSTALL_PREFIX before this change -- default_configure's
#    inline cmake call set it -- so a file-wide grep passes on the merge base
#    and proves nothing about the helper. tests/oracle-baseline.sh caught
#    exactly that and was right to.
_body=$(sed -n '/^mf_cmake() {/,/^}/p' lib/framework.sh)
case "$_body" in
  *CMAKE_INSTALL_PREFIX*) _pass helper-supplies-install-prefix ;;
  *) _bad helper-supplies-install-prefix "mf_cmake does not set CMAKE_INSTALL_PREFIX" ;;
esac

# 4. The knob is reset between recipes. PKG_* are plain shell globals in one
#    long-lived process, so without a reset the first recipe to set Release
#    would impose it on every later recipe that deliberately sets none -- the
#    exact behaviour change this convergence was written to avoid.
if grep -qE '^[[:space:]]*PKG_CMAKE_BUILD_TYPE=""' lib/framework.sh; then
  _pass build-type-reset-between-recipes
else
  _bad build-type-reset-between-recipes "reset_recipe does not clear PKG_CMAKE_BUILD_TYPE"
fi

printf 'DONE: cmake-single-entry\n'
exit "$_fail"
