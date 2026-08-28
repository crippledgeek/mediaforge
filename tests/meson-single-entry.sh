#!/bin/sh
# Pins that meson is SET UP in exactly one place (mf_meson, lib/framework.sh).
#
# Eighteen call sites across 13 recipes repeated the same four flags --
# --prefix, --buildtype, --default-library, --libdir -- differing only in build
# directory and -D options. They agreed only because each was copied from the
# last, and lv2 alone carried six of them.
#
# The sibling of tests/cmake-single-entry.sh, kept separate because it is a
# separate rule about a separate tool. It also covers the six lv2 sites that
# sit inside stamp_check guards in pkg_install, which the behaviour-diff harness
# used during the convergence could not reach -- a grep does not care which
# branch a call lives in, which is exactly why the invariant is worth having
# beyond the one-off comparison.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# THE FLOOR: every claim below is "grep finds nothing", which an empty recipes/
# would satisfy having checked nothing.
_sites=$(grep -rcE '(^|[^_[:alnum:]])mf_meson ' recipes/ 2>/dev/null \
         | awk -F: '{s+=$2} END{print s+0}')
if [ "$_sites" -ge 15 ]; then
  _pass meson-sites-present-to-check
else
  _bad meson-sites-present-to-check "only $_sites mf_meson call(s); expected >=15"
fi

# 1. Nothing sets meson up outside the helper. `meson configure`, `compile` and
#    `install` act on an already-configured tree and carry none of the flags
#    this rule is about, so they are excluded rather than counted as offenders.
_direct=$(grep -rn 'run meson' recipes/ 2>/dev/null \
          | grep -vE 'meson (configure|compile|install)' || true)
if [ -z "$_direct" ]; then
  _pass no-recipe-sets-up-meson-directly
else
  _bad no-recipe-sets-up-meson-directly "$(printf '%s' "$_direct" | head -3)"
fi

# 2. The four hoisted flags appear in no recipe. Any one of them re-specified at
#    a call site would be passed twice -- and for --buildtype that means the
#    recipe's copy silently wins over the knob, which is the drift this whole
#    convergence exists to prevent.
#
#    Scoped to the mf_meson invocations themselves, continuation lines included.
#    A bare grep of recipes/ for these flags also matches every autotools
#    ./configure --prefix= and openssl's ./Configure --libdir=, which are a
#    different tool entirely -- the first draft did exactly that and reported
#    three unrelated recipes as offenders.
_inv=$(awk '
  /(^|[^_[:alnum:]])mf_meson /            { inv=1 }
  inv                                      { print FILENAME": "$0 }
  inv && !/\\$/                            { inv=0 }
' recipes/*/*.sh 2>/dev/null || true)
_dupe=$(printf '%s\n' "$_inv" \
        | grep -E -- '--prefix=|--buildtype=|--default-library=|--libdir=' || true)
if [ -z "$_inv" ]; then
  # On a tree with no mf_meson at all -- the merge base -- "no call site
  # re-specifies a hoisted flag" is true because there are no call sites. That
  # is a vacuous pass, and tests/oracle-baseline.sh counts it as proof the
  # assertion cannot be guarding its change. It caught this one.
  _bad hoisted-flags-not-respecified "no mf_meson invocations found — claim would be vacuous"
elif [ -z "$_dupe" ]; then
  _pass hoisted-flags-not-respecified
else
  _bad hoisted-flags-not-respecified "$(printf '%s' "$_dupe" | head -3)"
fi

# 3. Scoped to mf_meson's OWN body, not the file: lib/framework.sh mentions
#    --prefix elsewhere (default_configure's ./configure line), so a file-wide
#    grep would pass on the merge base and prove nothing about the helper.
_body=$(sed -n '/^mf_meson() {/,/^}/p' lib/framework.sh)
case "$_body" in
  *--default-library=static*) _pass helper-forces-static-library ;;
  *) _bad helper-forces-static-library "mf_meson does not pass --default-library=static" ;;
esac

# 4. The buildtype knob is reset between recipes, like PKG_CMAKE_BUILD_TYPE.
if grep -qE '^[[:space:]]*PKG_MESON_BUILDTYPE=""' lib/framework.sh; then
  _pass buildtype-reset-between-recipes
else
  _bad buildtype-reset-between-recipes "reset_recipe does not clear PKG_MESON_BUILDTYPE"
fi

printf 'DONE: meson-single-entry\n'
exit "$_fail"
