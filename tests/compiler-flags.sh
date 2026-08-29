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
# -O2. Three times slower, shipped in every release since the first commit.
# dav1d and svtav1 were unaffected because meson and cmake set optimization
# themselves, which is why the symptom never showed up as a whole-tree slowdown.
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
  _glob "$1" "$(_compose "$2" "$3")" "$4" "own=[$2] user=[$3]"
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
  _glob_not "$1" "$(_compose "$2" "$3")" "$4" "own=[$2] user=[$3]"
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
  _glob "$1" "$_out" "$4" "own=[$2] user=[$3]"
}
_lt user-ldflags-preserved '-L/p/lib' '-L/opt/lib' '*-L/opt/lib*'
_lt user-ldflags-last      '-L/p/lib' '-L/opt/lib' '*-L/opt/lib'
_lt own-ldflags-present    '-L/p/lib' '-L/opt/lib' '-L/p/lib*'
# No -O is invented for the link line: mf_compose_flags is the plain rule, and
# an -O2 appearing here would mean mf_compose_cflags had been reused by mistake.
_lt ldflags-gets-no-opt-default '-L/p/lib' '' '-L/p/lib'

# --- composition must not glob against the working directory ----------------
# Unquoted expansion splits AND globs. The splitting is wanted; the globbing is
# not. Reproduced under dash before the fix: with files named `-DFOO=a.h` and
# `-DFOO=b.h` in the CWD, a single `-DFOO=*.h` came back as two flags, and every
# later compiler invocation inherited both. Runs in a subshell in a temp dir so
# the fixture files cannot touch the repo.
_globdir=$(mktemp -d 2>/dev/null || printf '')
if [ -n "$_globdir" ] && command -v mf_compose_flags >/dev/null 2>&1; then
  : > "$_globdir/-DFOO=a.h"
  : > "$_globdir/-DFOO=b.h"
  _got=$(cd "$_globdir" && mf_compose_flags '-I/p/include' '-DFOO=*.h')
  if [ "$_got" = '-I/p/include -DFOO=*.h' ]; then
    _pass user-flags-not-glob-expanded
  else
    _bad user-flags-not-glob-expanded "got=[$_got]"
  fi
  # The caller's own noglob state survives: POSIX sh has no function-local
  # options, so a bare `set +f` would switch globbing back on for a caller that
  # had deliberately disabled it.
  _got=$(set -f; mf_compose_flags '-a' '-b' >/dev/null; case $- in *f*) printf 'kept' ;; *) printf 'CLOBBERED' ;; esac)
  if [ "$_got" = kept ]; then
    _pass caller-noglob-state-preserved
  else
    _bad caller-noglob-state-preserved "caller had set -f; after the call it was $_got"
  fi
  rm -f "$_globdir/-DFOO=a.h" "$_globdir/-DFOO=b.h"
  rmdir "$_globdir" 2>/dev/null || true
else
  _bad user-flags-not-glob-expanded "no composer or no temp dir — claim would be vacuous"
  _bad caller-noglob-state-preserved "no composer or no temp dir — claim would be vacuous"
fi

# A tab-separated CFLAGS is what a here-doc or a mangled profile produces. The
# -O detection anchors on a space, so without folding tabs first this reads as
# "no -O chosen" and appends a second one.
_t_not user-opt-tab-separated '-I/p/include' '-g	-O2' '*-O2 *'

# --- PKG_C_STD: a declaration, not a mechanism copied sixteen times ---------
# Sixteen recipes carried -std=gnu11, because GCC 15 defaults to -std=gnu23 and
# those sources predate it. In 12 of them the entire body of pkg_prepare() was
# the append and its export. Beyond the duplication, it meant a recipe wanting a
# REAL prepare step had to remember to carry the flag along with it -- librtmp,
# pkg-config, bs2b and libvorbis all did, which is how the shapes diverged.
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

# --- no recipe may REPLACE the composed flag line ---------------------------
# The ownership fix reaches a recipe only if the recipe extends $CFLAGS rather
# than assigning over it. Two did the latter and were invisible to it:
#
#   bzip2  passed CFLAGS= as a make COMMAND-LINE variable, which outranks the
#          environment entirely -- so the operator's flags, the -O2 default and
#          everything else were discarded, and its own hardcoded "-O2 -g" is why
#          libbz2.a was the only archive in workspace/lib carrying DWARF.
#   dav1d  did `export CFLAGS="-arch arm64"` on macOS ARM, replacing the whole
#          line: no -fPIC, no optimization, no user flags, and -- the part that
#          is a plain bug rather than a policy question -- no -I$PREFIX/include.
#
# Both are the same defect this file exists to pin, one layer down. A recipe
# setting CFLAGS is fine; a recipe setting it WITHOUT deriving from $CFLAGS is
# not. The check looks for an assignment whose right-hand side never mentions
# $CFLAGS, which is exactly the distinction.
# The dollar is built rather than written literally. Inside single quotes the
# linter reads it as a failed expansion (SC2016), and it is neither an expansion
# nor a mistake here -- it is the character being searched for. Note also that a
# comment line may not BEGIN with the linter's own name, or the line is parsed
# as a directive (SC1072/SC1073); that is why this paragraph is worded around it.
_d='$'
# Comment lines are excluded first. Both fixed recipes now carry a comment
# QUOTING the old assignment so the next reader knows why the derivation
# matters, and a check that reads prose as code reports the explanation as the
# offence -- which is exactly what happened on the first run of this assertion.
_tmp_clobber=$(mktemp) || exit 1
trap 'rm -f "$_tmp_clobber"' EXIT
_cleanup_on_signal
_clobber=$(grep -rnE '(^|[^_[:alnum:]])(export +)?CFLAGS=' recipes/ 2>/dev/null \
           | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
           | grep -vF "CFLAGS=\"${_d}CFLAGS" \
           | grep -vF "${_d}CFLAGS\"" \
           | grep -vE "_cflagsbackup|CFLAGS=\"[${_d}]_" || true)
# A recipe may route the derivation through a helper -- giflib passes
# CFLAGS="$(_giflib_cflags)" on its make line because giflib's Makefile ASSIGNS
# CFLAGS and only a command-line macro overrides it. That is derivation, not
# replacement, but it looks identical to a grep of the assignment alone. Follow
# the named helper into its own body and drop the line if the helper derives.
#
# _fn_body is the shared reader in tests/lib-assert.sh, the same one
# tests/debug-levels.sh scans recipes with -- one implementation of "read this
# function's body", rather than each test growing its own.
printf '%s\n' "$_clobber" | while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  _f=${_line%%:*}
  _helper=$(printf '%s' "$_line" | grep -oE "CFLAGS=\"[${_d}]\(_[a-z0-9_]+\)" | sed 's/[^_a-z0-9]//g')
  if [ -n "$_helper" ] && [ -f "$_f" ] && _uses_composed_cflags "$_f" "$_helper"; then
    continue
  fi
  printf '%s\n' "$_line"
# No `|| true`: a failure here would leave the file empty and the assertion
# would report PASS -- a gate whose breakage looks like success, which is the
# failure mode this file exists to catch elsewhere. 2>/dev/null stays: _fn_body
# on an unreadable file yields no output and the line then SURVIVES as an
# offence, which is the safe direction.
done > "$_tmp_clobber" 2>/dev/null
_clobber=$(cat "$_tmp_clobber" 2>/dev/null)
rm -f "$_tmp_clobber"

if [ -z "$_clobber" ]; then
  _pass no-recipe-replaces-composed-cflags
else
  _bad no-recipe-replaces-composed-cflags "$(printf '%s' "$_clobber" | head -3)"
fi

printf 'DONE: compiler-flags\n'
exit "$_fail"
