#!/bin/sh
# Pins that no recipe removes a tree with a bare `rm -rf`, and that each of the
# two removal POLICIES fires: mf_reset_dir / mf_remove_tree kill the recipe when
# the removal is refused, mf_remove_temp reports and continues.
#
# Before this, twenty sites reset a build directory themselves: fourteen as the
# `rm -rf X && mkdir -p X` one-liner (thirteen of them over a literal `build`,
# the fourteenth over a $DISTDIR path), three as the same pair on two lines, one
# -- x265 -- as a two-line pair over three sibling directories with the rm's
# stderr sent to /dev/null, and two as a bare removal the build system then
# recreated. Not one of them looked at either status. Nothing in mediaforge
# sets `set -e`, so a failed `rm -rf` short-circuits
# the `&&`, the directory is never recreated, and the recipe configures against
# the PREVIOUS build's cache -- which is a silent success now and a link error in
# FFmpeg later, nowhere near the recipe that caused it (GH-84).
#
# The second policy exists because the two removals in this tree answer to
# different reasons. Dropping files a previous version installed MUST succeed --
# the staged install merges with a tar pipe and the merge only ever adds, so the
# removal is the only way anything ever leaves $PREFIX (GH-86). Removing a
# `mktemp -d` scratch tree need not: a failure there leaks a temp directory and
# dying over it would abort a build. Naming both is what lets the grep below
# demand that recipes/ contains no third answer.
#
# The behavioural half is the load-bearing one. A grep can only see that the
# call sites route through the helper; it cannot see whether the helper's guard
# fires, and a guard nothing has ever tripped is a guard nobody knows the
# polarity of. So the two failure modes are provoked against a real directory
# and their MESSAGES are matched, not merely their exit status: on a tree
# without the helper `mf_reset_dir` is simply not a command, and a status-only
# assertion would read 127 as "the guard fired" and pass on the merge base.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
# SCRIPT_DIR is how lib/utils.sh locates its own dependency (lib/stage.sh);
# mediaforge.sh sets it from $0, and $ROOT is the same directory here.
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. lib/utils.sh
# Sourced only if it is there. tests/oracle-baseline.sh runs this file against
# the MERGE BASE, where lib/remove.sh does not exist yet -- and under `set -e` a
# failed `.` aborts the run, which the gate reads as "asserted nothing at all"
# rather than as the nine failing assertions it should see. Absent the file the
# helpers are simply undefined, which is what every assertion below then
# reports.
# shellcheck source=lib/remove.sh
[ -f lib/remove.sh ] && . lib/remove.sh
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
_cleanup_on_signal

# u+rwX before the removal: the fixtures below deliberately make a parent
# unwritable, and a temp tree in that state outlives the run otherwise.
_tmp=$(mktemp -d)
trap 'chmod -R u+rwX "$_tmp" 2>/dev/null || true; rm -rf "$_tmp"' EXIT

# 1. The mechanism exists once. Read through _lib_code, because this file's own
#    header quotes the helper's name in prose and so does framework.sh's.
_reasons=""
for _fn in mf_reset_dir mf_remove_tree mf_remove_temp; do
  _defs=$(_lib_code | grep -c "$_fn() {" || true)
  [ "$_defs" = 1 ] || _reasons="$_reasons $_fn:$_defs"
done
_verdict each-helper-defined-once "$_reasons"

# 2. THE FLOOR for assertion 3, which is a "grep finds nothing" claim: a
#    recipes/ that called the helper nowhere would satisfy it having verified
#    nothing.
# The floor is the CURRENT count, not a lower guess: at eighteen it would also
# tolerate two of them being deleted outright rather than replaced, which is the
# regression this branch exists to prevent wearing a different hat. A recipe
# added later that resets a directory only pushes the count up.
_sites=$(grep -rlE '(^|[^_[:alnum:]])mf_reset_dir ' recipes/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$_sites" -ge 20 ]; then
  _pass recipes-route-through-the-helper
else
  _bad recipes-route-through-the-helper "only $_sites recipe(s) call mf_reset_dir; expected >=20"
fi

# 3. No recipe resets a directory on its own again. Both spellings the tree
#    carried are caught: the `&&` one-liner, and the pair split over two lines
#    -- the second is what a copy of the first becomes once someone reformats
#    it, so catching only the one-liner would let the defect back in unchanged.
#    Read through _code_only: recipes explain removed idioms in prose, and a
#    grep that reads comments reports the explanation as the offence.
#    `prev` is carried over BLANK lines rather than reset by them, and that is
#    the difference between catching a reformatted copy and only appearing to.
#    _code_only blanks a comment-only line to the empty string, so a pair with a
#    comment between the two statements -- which is exactly what a copy grows
#    when someone explains it -- slipped past the first version of this awk with
#    all seven assertions green.
#
#    Each file's hits are joined with an explicit newline: `$(...)` strips the
#    trailing one, so concatenating them directly ran eighteen offenders
#    together into a single line and the `head -3` cap below never engaged.
_own=""
for _f in $(find recipes -name '*.sh' | sort); do
  _hits=$(_code_only "$_f" | awk -v F="$_f" '
    /rm -rf/ && /mkdir/            { print F ":" NR ": " $0 }
    prev ~ /rm -rf/ && /mkdir -p/  { print F ":" NR ": " prev " / " $0 }
    { if ($0 ~ /[^[:space:]]/) prev = $0 }
  ')
  [ -z "$_hits" ] || _own="$_own$_hits
"
done
_verdict no-recipe-resets-a-build-dir-itself "$(printf '%s' "$_own" | head -3)"

# 3b. ...and no recipe removes a tree any other way either. This is the claim
#     the two named policies buy: with both spelled out in lib/framework.sh, a
#     bare `rm -rf` in a recipe is always a third answer nobody decided on, so
#     the assertion needs no allowlist to maintain -- and an allowlist is
#     maintained by whoever adds the next site, which is precisely who does not
#     know it exists.
_bare=""
for _f in $(find recipes -name '*.sh' | sort); do
  _hits=$(_code_only "$_f" | grep -n 'rm -rf' | sed "s|^|$_f:|")
  [ -z "$_hits" ] || _bare="$_bare$_hits
"
done
_verdict no-recipe-removes-a-tree-unguarded "$(printf '%s' "$_bare" | head -3)"

# 4. A removal that cannot happen is fatal. Removing `build` needs write
#    permission on its PARENT, not on `build` itself, so a 0555 parent stops the
#    rm while leaving every path in it readable -- which is what lets the same
#    fixture serve assertion 5, where the rm has nothing to do and the mkdir is
#    the statement that fails.
_ro="$_tmp/readonly"
mkdir -p "$_ro/build"
: > "$_ro/build/stale.cache"
chmod 555 "$_ro"
# Does the fixture BITE? Under root, and on any filesystem that does not honour
# the bit, every operation below succeeds and the two assertions would report
# the guard missing when what is missing is the fixture. Reported, not skipped:
# tests/oracle-baseline.sh counts assertion lines, and a silent skip is a test
# that has quietly stopped testing.
if mkdir "$_ro/probe" 2>/dev/null; then
  rmdir "$_ro/probe"
  _bad removal-failure-is-fatal "fixture unavailable: $_ro stayed writable after chmod 555"
  _bad creation-failure-is-fatal "fixture unavailable: $_ro stayed writable after chmod 555"
else
  # die() exits, so each call runs in a subshell that the exit terminates.
  _out=$( (mf_reset_dir "$_ro/build") 2>&1 || true)
  _glob removal-failure-is-fatal "$_out" '*Failed to remove*' 'mf_reset_dir on a directory it cannot unlink'

  # 5. ...and so is a creation that cannot happen. Distinct message, because the
  #    two statuses fail for different reasons and a single guard covering both
  #    would name neither -- a mutation that drops the mkdir's `|| die` leaves
  #    assertion 4 green.
  _out=$( (mf_reset_dir "$_ro/fresh") 2>&1 || true)
  _glob creation-failure-is-fatal "$_out" '*Failed to create*' 'mf_reset_dir under a parent it cannot write'
fi

# The success-path contract, asserted the same way for one directory and for
# three: every directory named exists afterwards AND is empty. Written once
# because assertions 6 and 7 differ only in how many directories they hand over
# -- a second copy would be where the emptiness half quietly stopped being
# checked for the multi-directory case, which is the half that matters (a helper
# that never removed anything satisfies "exists" perfectly, and that stale tree
# is what this fix exists to prevent).
#
# The call is in a subshell for the same reason assertions 4 and 5 are: if a
# regression made the SUCCESS path die, an unwrapped call would take the whole
# file with it, and tests/oracle-baseline.sh reads a missing DONE as "the test
# aborted" -- a different and misleading diagnosis from "an assertion failed".
#
# `ls -A` rather than `find -mindepth 1`: -mindepth is a GNU extension, and this
# suite runs where /bin/sh is dash and find is whatever the host ships.
_reset_is_clean() { # assertion-name  dir...
  _ric_name="$1"; shift
  _ric_why=""
  ( mf_reset_dir "$@" ) >/dev/null 2>&1 || _ric_why=" helper returned non-zero"
  for _ric_d in "$@"; do
    if [ ! -d "$_ric_d" ]; then
      _ric_why="$_ric_why $_ric_d-missing"
    elif [ -n "$(ls -A "$_ric_d" 2>/dev/null)" ]; then
      _ric_why="$_ric_why $_ric_d-not-emptied"
    fi
  done
  _verdict "$_ric_name" "$_ric_why"
}

# 6. The success path still does what the twenty call sites were written to do.
_ok="$_tmp/ok/build"
mkdir -p "$_ok"
: > "$_ok/CMakeCache.txt"
_reset_is_clean reset-empties-and-recreates "$_ok"

# 7. The variadic form, which recipes/video/x265.sh needs: three sibling
#    directories reset as one step. A helper taking a single directory would
#    silently reset only the first and leave the other two carrying the previous
#    bit-depth's objects.
_multi="$_tmp/multi"
mkdir -p "$_multi/8bit" "$_multi/10bit" "$_multi/12bit"
: > "$_multi/10bit/leftover.o"
_reset_is_clean reset-handles-every-directory-given \
  "$_multi/8bit" "$_multi/10bit" "$_multi/12bit"

# 8. An empty argument is refused, rather than reaching `rm -rf -- ""` and then
#    dying on the mkdir with a message that names no path. `$_src` unset is the
#    way a recipe produces one, and the guard is the cheapest place in the tree
#    to hold the line lib/download.sh and lib/cleanup.sh already hold with
#    `${x:?}` at their own removals.
_empty=""
_out=$( (mf_reset_dir "$_empty") 2>&1 || true)
_glob empty-argument-refused "$_out" '*empty path argument*' 'mf_reset_dir with an empty argument'

# 9. ...and so is a call with no arguments, which the loop would otherwise treat
#    as "nothing to do". A function whose contract is "this directory is now
#    empty and exists" has no honest way to return success having done nothing.
_out=$( (mf_reset_dir) 2>&1 || true)
_glob no-argument-call-refused "$_out" '*no directory to reset*' 'mf_reset_dir with no arguments'

# 10. mf_remove_tree removes, and dies when it cannot. The 0555 parent from
#     assertions 4 and 5 is reused: it is the same refusal, reached through the
#     entry point recipes/hwaccel/amf.sh and recipes/tools/meson.sh call.
_gone="$_tmp/gone"
mkdir -p "$_gone/tree"
: > "$_gone/tree/old-header.h"
_reasons=""
( mf_remove_tree "$_gone/tree" ) >/dev/null 2>&1 || _reasons=" helper returned non-zero"
[ -e "$_gone/tree" ] && _reasons="$_reasons path-survived"
_verdict remove-tree-removes "$_reasons"

if [ -d "$_ro/build" ]; then
  _out=$( (mf_remove_tree "$_ro/build") 2>&1 || true)
  _glob remove-tree-failure-is-fatal "$_out" '*Failed to remove*' 'mf_remove_tree on a path it cannot unlink'
else
  _bad remove-tree-failure-is-fatal "fixture unavailable: $_ro/build was removed by an earlier assertion"
fi

_out=$( (mf_remove_tree) 2>&1 || true)
_glob remove-tree-no-argument-refused "$_out" '*no path to remove*' 'mf_remove_tree with no arguments'

# 11. mf_remove_temp is the OTHER policy, and the difference is the whole point:
#     a failed temp cleanup warns and the caller keeps going. Asserted as both
#     halves -- the warning is emitted AND the function returns 0 -- because a
#     mutation that turned the warn into a die would still print something.
_out=$( (mf_remove_temp "$_ro/build" && printf 'CONTINUED\n') 2>&1 || true)
_glob remove-temp-warns-and-continues "$_out" '*WARNING*leaked*CONTINUED*' 'mf_remove_temp on a path it cannot unlink'

_scratch="$_tmp/scratch"
mkdir -p "$_scratch/probe"
: > "$_scratch/probe/probe.cu"
_reasons=""
( mf_remove_temp "$_scratch/probe" ) >/dev/null 2>&1 || _reasons=" helper returned non-zero"
[ -e "$_scratch/probe" ] && _reasons="$_reasons path-survived"
_verdict remove-temp-removes "$_reasons"

printf 'DONE: tree-removal-guards\n'
exit "$_fail"
