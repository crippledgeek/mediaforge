#!/bin/sh
# Pins compiler-flag OWNERSHIP (lib/flags.sh).
#
# mediaforge used to ASSIGN CFLAGS="-I$PREFIX/include" at startup. That did two
# damaging things at once, and neither was visible in a build log anyone read:
# it discarded whatever CFLAGS the user had exported, and -- because autotools
# supplies its own "-g -O2" only when CFLAGS is UNSET -- it suppressed that
# default, leaving every autotools recipe to compile at gcc's no-flag -O0.
#
# Measured on lame-3.100 before the fix: the build log carried zero -O and zero
# -g flags, and one encode of the same 20s fixture took 0.34s against 0.11s at
# -O2. Three times slower, shipped, for four years of releases. dav1d and
# svtav1 were unaffected because meson and cmake set optimization themselves,
# which is why the symptom never showed up as a whole-tree slowdown.
#
# The GNU coding standards state the rule this file enforces: CFLAGS belongs to
# the user ("Users expect to be able to specify CFLAGS freely themselves") and a
# package passes its own required flags "independently of CFLAGS".
#
# Sources lib/flags.sh CONDITIONALLY. On the merge base that file does not
# exist, and a `.` of a missing path under `set -e` aborts the script -- which
# tests/oracle-baseline.sh reports as a missing DONE sentinel rather than as the
# absent feature it is. Guarding the source lets every assertion below report
# FAIL on the base and still reach the sentinel.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

if [ -f lib/flags.sh ]; then
  # shellcheck source=lib/flags.sh
  . lib/flags.sh
fi

# Every assertion routes through here so the base -- where mf_compose_cflags is
# undefined -- reports a FAIL per claim rather than one abort for all of them.
_compose() { # own user
  if command -v mf_compose_cflags >/dev/null 2>&1; then
    mf_compose_cflags "$1" "${2-}"
  else
    printf ''
  fi
}

_t() { # assertion-name  own  user  case-glob  (matched against composed output)
  _out=$(_compose "$2" "$3")
  # shellcheck disable=SC2254  # $4 is a glob by design, not a literal
  case "$_out" in
    $4) _pass "$1" ;;
    *)  _bad "$1" "own=[$2] user=[$3] got=[$_out]" ;;
  esac
}

# The FLOOR that keeps the negative assertions honest. A "must not contain -O2"
# check is satisfied by the empty string, so on the merge base -- where
# mf_compose_cflags does not exist and _compose yields "" -- every _t_not below
# would report PASS having verified nothing. tests/oracle-baseline.sh counts a
# pass on the base as proof the assertion cannot be guarding its change, and it
# is right to: five of these passed vacuously before this guard was added.
# Requiring non-empty output first makes the negative claim conditional on the
# composer having actually run.
_t_not() { # assertion-name  own  user  case-glob  (must NOT match)
  _out=$(_compose "$2" "$3")
  if [ -z "$_out" ]; then
    _bad "$1" "composer produced nothing — negative claim would be vacuous"
    return
  fi
  # shellcheck disable=SC2254
  case "$_out" in
    $4) _bad "$1" "own=[$2] user=[$3] got=[$_out]" ;;
    *)  _pass "$1" ;;
  esac
}

# --- the user's flags survive, and win -------------------------------------
# Preserved at all: the whole defect was that they were discarded.
_t user-cflags-preserved       '-I/p/include' '-march=native' '*-march=native*'
# LAST, not merely present. Both gcc and clang resolve a repeated -O by taking
# the final one, so position is what makes "the user wins" true rather than
# accidental -- an ordering that puts mediaforge's -O2 after a user's -O0
# silently overrides the user's explicit choice.
_t user-cflags-last            '-I/p/include' '-march=native' '*-march=native'
# mediaforge's own include path is still delivered.
_t own-flags-present           '-I/p/include' '-march=native' '-I/p/include*'

# --- the optimization default ----------------------------------------------
# The restored default. Without it an autotools recipe lands on gcc's -O0.
_t default-opt-applied         '-I/p/include' ''        '*-O2*'
# A user CFLAGS of only whitespace is the shape an unset-but-exported variable
# takes (CFLAGS=" " in a profile, or an expansion that resolved to nothing). It
# must read as "no preference" and still get the default -- not as a choice.
_t default-opt-applied-blank   '-I/p/include' '   '     '*-O2*'
# ...and it must not leave the ragged spacing behind in the composed line.
_t_not blank-user-not-padded   '-I/p/include' '   '     '*  *'
# An explicit user choice suppresses the default entirely, rather than being
# appended after it and merely winning by position: a build that shows both
# -O2 and -O0 on the command line is confusing even when the outcome is right.
_t_not user-opt-not-doubled    '-I/p/include' '-O0'     '*-O2*'
_t     user-opt-respected      '-I/p/include' '-O0'     '*-O0*'

# --- boundaries of "did the user already pick an -O?" ----------------------
# Every -O spelling counts, not just the digits. -Og and -Os are the two a
# digit-only check misses, and -Og is the level GCC documents as the one to use
# for the edit-compile-debug cycle -- so getting it wrong would append -O2 after
# a debug build's own choice and quietly un-debug it.
_t_not user-opt-og-recognised  '-I/p/include' '-Og'     '*-O2*'
_t_not user-opt-os-recognised  '-I/p/include' '-Os'     '*-O2*'
_t_not user-opt-ofast-recognised '-I/p/include' '-Ofast' '*-O2*'
_t_not user-opt-bare-recognised  '-I/p/include' '-O'     '*-O2*'
# The negative boundary, and the reason the check is anchored on a leading
# space: -Wno-Overlength-strings CONTAINS the substring "-O". A naive
# `case $flags in *-O*)` treats it as an optimization choice and drops the
# default, putting that recipe back at -O0 -- the exact defect, reintroduced
# through the fix for it. This assertion is what separates the two
# implementations; nothing else here can tell them apart.
_t default-opt-survives-lookalike '-I/p/include' '-Wno-Overlength-strings' '*-O2*'

# --- the same ownership rule for LDFLAGS -----------------------------------
# LDFLAGS was assigned exactly as CFLAGS was, so it discarded the user's value
# for the same reason. It gets no optimization default -- nothing on the link
# line plays -O's role -- so it is composed by the shared splitter directly.
_lt() { # assertion-name  own  user  case-glob
  if command -v mf_compose_flags >/dev/null 2>&1; then
    _out=$(mf_compose_flags "$2" "$3")
  else
    _out=''
  fi
  # shellcheck disable=SC2254
  case "$_out" in
    $4) _pass "$1" ;;
    *)  _bad "$1" "own=[$2] user=[$3] got=[$_out]" ;;
  esac
}
_lt user-ldflags-preserved '-L/p/lib' '-L/opt/lib' '*-L/opt/lib*'
_lt user-ldflags-last      '-L/p/lib' '-L/opt/lib' '*-L/opt/lib'
_lt own-ldflags-present    '-L/p/lib' '-L/opt/lib' '-L/p/lib*'
# No -O is invented for the link line: mf_compose_flags is the plain rule, and
# an -O2 appearing here would mean mf_compose_cflags had been reused by mistake.
_lt ldflags-gets-no-opt-default '-L/p/lib' '' '-L/p/lib'

# --- PKG_C_STD: a declaration, not sixteen copies of a mechanism ------------
# Sixteen recipes each carried a pkg_prepare() whose entire body appended
# -std=gnu11 to CFLAGS and exported it, because GCC 15 defaults to -std=gnu23
# and those sources predate it. Beyond the duplication, it meant a recipe
# wanting a REAL prepare step had to remember to carry the flag along with it --
# librtmp and pkg-config both did, which is how the two shapes diverged.
# Matched as a regex whose "." stands in for the dollar sign, so this file never
# contains a literal $ inside quotes. Both the fixed-string and case-glob
# spellings trip SC2016 ("expressions don't expand in single quotes"), which is
# wrong here -- the dollar is source text being searched for, not an expansion --
# but writing it a way the linter cannot misread beats arguing with it.
if grep -qE -- '-std=.PKG_C_STD' lib/framework.sh 2>/dev/null; then
  _pass c-std-applied-by-framework
else
  _bad c-std-applied-by-framework "lib/framework.sh never applies PKG_C_STD"
fi

# Reset per recipe, like every other PKG_*. Without it the first recipe to
# declare gnu11 would impose it on every later recipe -- and since -std changes
# which language the compiler accepts, that silently alters builds that never
# asked for it.
if grep -qE '^[[:space:]]*PKG_C_STD=""' lib/framework.sh 2>/dev/null; then
  _pass c-std-reset-between-recipes
else
  _bad c-std-reset-between-recipes "reset_recipe does not clear PKG_C_STD"
fi

# The invariant: no recipe hand-rolls the append any more. A survivor would
# still work, which is exactly why nothing would notice it drifting.
_inline=$(grep -rn 'CFLAGS -std=' recipes/ 2>/dev/null || true)
if [ -z "$_inline" ]; then
  _pass no-recipe-inlines-c-std
else
  _bad no-recipe-inlines-c-std "$(printf '%s' "$_inline" | head -3)"
fi

# The floor for the assertion above: it is a "grep finds nothing" claim, and it
# would pass on a tree where no recipe needs a C standard at all.
_decl=$(grep -rcE '^PKG_C_STD=' recipes/ 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if [ "$_decl" -ge 12 ]; then
  _pass c-std-declarations-present
else
  _bad c-std-declarations-present "only $_decl recipe(s) declare PKG_C_STD; expected >=12"
fi

printf 'DONE: compiler-flags\n'
exit "$_fail"
