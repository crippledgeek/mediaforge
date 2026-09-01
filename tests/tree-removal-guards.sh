#!/bin/sh
# Pins that no recipe runs `rm` at all, and that each removal POLICY fires:
# mf_reset_dir / mf_remove_tree / mf_remove_file kill the recipe when the
# removal is refused, mf_remove_temp reports and continues.
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
# rather than as the failing assertions it should see. Absent the file the
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
for _fn in mf_reset_dir mf_remove_tree mf_remove_file mf_remove_temp; do
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

# 3b. ...and no recipe runs `rm` at all. This is the claim
#     the two named policies buy: with both spelled out in lib/remove.sh, a
#     bare `rm -rf` in a recipe is always a third answer nobody decided on, so
#     the assertion needs no allowlist to maintain -- and an allowlist is
#     maintained by whoever adds the next site, which is precisely who does not
#     know it exists.
# The floor for 3b, mirroring assertion 2: "grep finds nothing" is also
# satisfied by a recipes/ that calls neither helper, so a call site DELETED
# rather than replaced would pass. Four mf_remove_tree sites (amf, meson, xeve,
# xevd) and two files calling mf_remove_temp (nv-codec twice, lcevc).
_reasons=""
for _pair in mf_remove_tree:4 mf_remove_file:6 mf_remove_temp:2; do
  _fn=${_pair%:*}
  _min=${_pair#*:}
  _n=$(grep -rlE "(^|[^_[:alnum:]])$_fn " recipes/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$_n" -ge "$_min" ] || _reasons="$_reasons only $_n recipe(s) call $_fn; expected >=$_min."
done
_verdict recipes-route-through-the-removal-helpers "$_reasons"

_bare=""
for _f in $(find recipes -name '*.sh' | sort); do
  # ANY `rm`, not a list of spellings. `rm -rf`, `rm -fr`, `rm -r`,
  # `rm --recursive` and plain `rm -f` are one statement with one dropped status
  # between them, and a grep enumerating spellings is a rule that the next
  # reformat walks straight through. With four policies named in lib/remove.sh
  # there is no removal a recipe still has to hand-roll, so the claim can be the
  # simple one -- which is also the one that cannot rot.
  #
  # Anchored so `mf_remove_*` and a word ending in `rm` do not match, and read
  # through _code_only so the several comments that discuss "the rm" are not
  # reported as call sites.
  _hits=$(_code_only "$_f" | grep -nE '(^|[^_[:alnum:]-])rm[[:space:]]' | sed "s|^|$_f:|")
  [ -z "$_hits" ] || _bare="$_bare$_hits
"
done
_verdict no-recipe-runs-rm-itself "$(printf '%s' "$_bare" | head -3)"

# "This call DIED": the message came out AND control never came back.
#
# One verdict, not two assertions, because the halves are not equally new. On the
# merge base the helper does not exist, so the call fails, the `&&` never fires,
# and a separately-reported "control did not return" passes there having proved
# nothing -- tests/oracle-baseline.sh caught exactly that. Reported together, the
# claim is false on the base and true here.
#
# The FATAL prefix is load-bearing and was the reviewer's finding: die() prints
# `[mediaforge] FATAL:` and warn() prints `[mediaforge] WARNING:` with the same
# sentence after it, so matching the sentence alone is satisfied by a helper that
# warns and carries on -- the exact inverse of GH-84 and GH-86, and it survived a
# green suite until someone ran the mutant. The CONTINUED sentinel is the second
# half of the same claim, borrowed from the mf_remove_temp assertion that already
# used it for the opposite polarity.
_dies_with() { # assertion-name  message-needle  command...
  _dw_name="$1"
  _dw_needle="$2"
  shift 2
  _dw_out=$( ("$@" && printf 'CONTINUED\n') 2>&1 || true)
  _dw_why=""
  case "$_dw_out" in
    *FATAL*"$_dw_needle"*) ;;
    *) _dw_why=" no FATAL '$_dw_needle' in the output: got=[$_dw_out]." ;;
  esac
  case "$_dw_out" in
    *CONTINUED*) _dw_why="$_dw_why control returned to the caller instead of dying." ;;
  esac
  _verdict "$_dw_name" "$_dw_why"
}

# 4. A removal that cannot happen is fatal. Removing `build` needs write
#    permission on its PARENT, not on `build` itself, so a 0555 parent stops the
#    rm while leaving every path in it readable -- which is what lets the same
#    fixture serve assertion 5, where the rm has nothing to do and the mkdir is
#    the statement that fails.
_ro="$_tmp/readonly"
mkdir -p "$_ro/build"
: > "$_ro/build/stale.cache"
# A file directly INSIDE the read-only directory, planted before the chmod:
# assertion 13 needs a removal that fails, and unlinking needs write permission
# on the PARENT -- a file under $_ro/build would be removable, since that
# directory keeps its own default mode.
: > "$_ro/stale.so"
chmod 555 "$_ro"
# Does the fixture BITE? Under root, and on any filesystem that does not honour
# the bit, every operation below succeeds and the two assertions would report
# the guard missing when what is missing is the fixture. Reported, not skipped:
# tests/oracle-baseline.sh counts assertion lines, and a silent skip is a test
# that has quietly stopped testing.
# The result is recorded rather than branched on twice, because FOUR assertions
# depend on this fixture and the two later ones used to run outside the branch --
# under root they would have reported a missing message rather than an
# unavailable fixture, which is a misleading diagnosis of a working guard.
_ro_bites=yes
_ro_why="fixture unavailable: $_ro stayed writable after chmod 555"
if mkdir "$_ro/probe" 2>/dev/null; then
  rmdir "$_ro/probe"
  _ro_bites=no
fi
if [ "$_ro_bites" = no ]; then
  _bad removal-failure-is-fatal "$_ro_why"
  _bad removal-failure-stops-the-recipe "$_ro_why"
  _bad creation-failure-is-fatal "$_ro_why"
  _bad creation-failure-stops-the-recipe "$_ro_why"
else
  # die() exits, so each call runs in a subshell that the exit terminates.
  _dies_with removal-failure-is-fatal 'Failed to remove' mf_reset_dir "$_ro/build"

  # 5. ...and so is a creation that cannot happen. Distinct message, because the
  #    two statuses fail for different reasons and a single guard covering both
  #    would name neither -- a mutation that drops the mkdir's `|| die` leaves
  #    assertion 4 green.
  _dies_with creation-failure-is-fatal 'Failed to create' mf_reset_dir "$_ro/fresh"
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
_dies_with empty-argument-refused 'empty path argument' mf_reset_dir "$_empty"

# 9. ...and so is a call with no arguments, which the loop would otherwise treat
#    as "nothing to do". A function whose contract is "this directory is now
#    empty and exists" has no honest way to return success having done nothing.
_dies_with no-argument-call-refused 'no directory to reset' mf_reset_dir

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

if [ "$_ro_bites" = yes ] && [ -d "$_ro/build" ]; then
  _dies_with remove-tree-failure-is-fatal 'Failed to remove' mf_remove_tree "$_ro/build"
elif [ "$_ro_bites" = yes ]; then
  _bad remove-tree-failure-is-fatal "fixture unavailable: $_ro/build was removed by an earlier assertion"
else
  _bad remove-tree-failure-is-fatal "$_ro_why"
fi

_dies_with remove-tree-no-argument-refused 'no path to remove' mf_remove_tree

# 11. mf_remove_temp is the OTHER policy, and the difference is the whole point:
#     a failed temp cleanup warns and the caller keeps going. Asserted as both
#     halves -- the warning is emitted AND the function returns 0 -- because a
#     mutation that turned the warn into a die would still print something.
if [ "$_ro_bites" = yes ]; then
  _out=$( (mf_remove_temp "$_ro/build" && printf 'CONTINUED\n') 2>&1 || true)
  _glob remove-temp-warns-and-continues "$_out" '*WARNING*leaked*CONTINUED*' 'mf_remove_temp on a path it cannot unlink'
else
  _bad remove-temp-warns-and-continues "$_ro_why"
fi

_scratch="$_tmp/scratch"
mkdir -p "$_scratch/probe"
: > "$_scratch/probe/probe.cu"
_reasons=""
( mf_remove_temp "$_scratch/probe" ) >/dev/null 2>&1 || _reasons=" helper returned non-zero"
[ -e "$_scratch/probe" ] && _reasons="$_reasons path-survived"
_verdict remove-temp-removes "$_reasons"

# 12. The product SOURCES the policy. This is what the split into its own file
#     costs if nobody watches it: delete the line from mediaforge.sh and every
#     helper becomes an unset command, whose "not found" is swallowed by the
#     first `>/dev/null 2>&1` it meets -- twenty resets and four drops silently
#     become no-ops, reverting GH-84 and GH-86 together, with the suite still
#     green because both test files source lib/remove.sh themselves.
_wired mediaforge-sources-the-removal-policy mediaforge.sh 'lib/remove.sh'

#     ...and sources it BEFORE the framework, whose mf_reset_dir callers are
#     recipes loaded later still. Order asserted rather than described, because
#     the header of lib/remove.sh states it as a fact.
_reasons=""
_ln_remove=$(_code_line mediaforge.sh 'lib/remove\.sh')
_ln_framework=$(_code_line mediaforge.sh 'lib/framework\.sh')
if [ -z "$_ln_remove" ] || [ -z "$_ln_framework" ]; then
  _reasons=" mediaforge.sh sources one of the two not at all (remove=[$_ln_remove] framework=[$_ln_framework])"
elif [ "$_ln_remove" -ge "$_ln_framework" ]; then
  _reasons=" lib/remove.sh is sourced at line $_ln_remove, after lib/framework.sh at $_ln_framework"
fi
_verdict removal-policy-sourced-before-the-framework "$_reasons"

# 13. mf_remove_file: the non-recursive policy, guarded the same way. Its
#     failure is provoked with a read-only PARENT, since removing a file needs
#     write permission there rather than on the file itself.
if [ "$_ro_bites" = yes ]; then
  _dies_with remove-file-failure-is-fatal 'Failed to remove file' mf_remove_file "$_ro/stale.so"
else
  _bad remove-file-failure-is-fatal "$_ro_why"
fi

# 14. ...and it removes, and an unmatched glob is NOT a failure -- which is the
#     property every converted site depends on, since they all name a `.so*`
#     pattern that a static-only build may legitimately have nothing for.
_files="$_tmp/files"
mkdir -p "$_files"
: > "$_files/libprobe.so"
_reasons=""
( mf_remove_file "$_files/libprobe.so" "$_files"/libabsent.so* ) >/dev/null 2>&1 ||
  _reasons=" the helper returned non-zero"
[ -e "$_files/libprobe.so" ] && _reasons="$_reasons the file survived"
_verdict remove-file-removes-and-tolerates-an-unmatched-glob "$_reasons"

# 15. mf_remove_temp's own two edges, which nothing watched: a no-argument call
#     is a caller bug like everywhere else, while an EMPTY argument is the one
#     case this policy deliberately skips rather than dying on -- a mktemp -d
#     that never happened is nothing to clean up.
_dies_with remove-temp-no-argument-refused 'no path to remove' mf_remove_temp
_empty=""
_out=$( (mf_remove_temp "$_empty" && printf 'CONTINUED\n') 2>&1 || true)
_glob remove-temp-skips-an-empty-path "$_out" '*CONTINUED*' 'mf_remove_temp with an empty argument'

printf 'DONE: tree-removal-guards\n'
exit "$_fail"
