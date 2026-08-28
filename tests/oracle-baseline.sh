#!/bin/sh
# Oracle baseline: a test that asserts a NEW behaviour must fail on the tree
# that lacks it.
#
# A test file's real claim is not "these assertions pass" — it is "these
# assertions would have caught the defect". Nothing checks the second claim, so
# it rots silently: an oracle can drift into matching an error message, a
# fixture path can collide with the value it is meant to distinguish, and the
# suite stays green either way. Both happened on this branch, and both were
# found by a reviewer running the file against the merge base by hand.
#
# This runs that check as a gate. Every file it selects is executed against a
# pristine export of the merge base, where it must assert, fail every assertion
# it reaches, and run to completion — the last proven by a DONE sentinel the
# file prints, because a test that ABORTS on the baseline emits almost nothing
# and would otherwise score a free pass.
#
# THE FILE LIST IS DERIVED, NOT MAINTAINED. A hand-written list is a thing to
# remember, and this file exists because things people must remember are not
# reliable. The population that matters is "test files this branch ADDED",
# which git already knows:
#   * a new test written later is included automatically;
#   * a test whose subject is already merged is excluded automatically, because
#     it is modified rather than added (tests/libressl-pin-asm.sh is the current
#     example — no paragraph here has to stay true about it);
#   * once the branch merges and the base advances, nothing is added relative to
#     it, and the gate SKIPS. That is the correct end state, not a hole: "this
#     test would have caught the defect" is a claim about the branch that
#     introduced the behaviour, and it stops meaning anything once the behaviour
#     is the baseline.
#
# KNOWN GAP, stated rather than papered over: a MODIFIED existing test file
# escapes this gate. Catching those needs per-assertion provenance, which git
# does not give us. This is the honest trade against a list nobody maintains.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

BASELINE_REF="${BASELINE_REF:-develop}"
_fail=0

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'SKIP: oracle baseline needs a git checkout\n'
  exit 0
fi
if ! git rev-parse --verify --quiet "$BASELINE_REF" >/dev/null; then
  printf 'SKIP: baseline ref %s not found\n' "$BASELINE_REF"
  exit 0
fi

# The MERGE BASE, not the tip of the ref. They are the same commit until someone
# merges into the ref while this branch is open; after that, the tip carries
# other people's work and testing against it is a different, weaker claim than
# the prose above makes.
if ! _base=$(git merge-base "$BASELINE_REF" HEAD 2>/dev/null); then
  printf 'SKIP: no merge base between HEAD and %s\n' "$BASELINE_REF"
  exit 0
fi

# Untracked files are unioned in: --diff-filter=A compares the base to the
# working tree for TRACKED paths only, so a new test file that has not been
# `git add`ed is invisible to it. "Remember to stage before the gate counts it"
# is the same category of thing as the hand-written list this replaced, and it
# fails silently — the gate would pass on the files it did find and say nothing
# about the one it missed.
# tests/lib-*.sh is a SOURCED LIBRARY, not a runnable test: it defines shared
# helpers and asserts nothing, so "every assertion fails on the base" is not a
# claim it can make -- running it here would fail it for having no assertions,
# which is true and says nothing about whether the branch is guarded. The
# exclusion is announced below rather than applied silently, and the one way it
# could become a hiding place -- a real test smuggled in under the prefix and
# wired into the suite -- is checked immediately after.
_files=$( { git diff --name-only --diff-filter=A "$_base" -- 'tests/*.sh'
            git ls-files --others --exclude-standard -- 'tests/*.sh'; } \
          | sort -u | grep -v '^tests/oracle-baseline\.sh$' || true)
_libs=$(printf '%s\n' "$_files" | grep '^tests/lib-[^/]*\.sh$' || true)
_files=$(printf '%s\n' "$_files" | grep -v '^tests/lib-[^/]*\.sh$' || true)
if [ -n "$_libs" ]; then
  printf '%s\n' "$_libs" | while read -r _lib; do
    [ -n "$_lib" ] || continue
    printf 'EXCLUDED: %s is a sourced library, not a test — it makes no assertions\n' "$_lib"
  done
  # A library the suite RUNS is a test wearing a library's name, and it would
  # have just been excused from the gate. Checked against the runner, not
  # against the file, because the runner is what decides.
  _smuggled=$(printf '%s\n' "$_libs" | while read -r _lib; do
                [ -n "$_lib" ] || continue
                grep -q "^sh $_lib\$" tests/run.sh && printf '%s\n' "$_lib"
              done)
  if [ -n "$_smuggled" ]; then
    printf 'FAIL: %s is run by tests/run.sh, so it is a test, not a library\n' "$_smuggled" >&2
    exit 1
  fi
fi
if [ -z "$_files" ]; then
  printf 'SKIP: no test files added since %s — nothing to baseline\n' "$(git rev-parse --short "$_base")"
  exit 0
fi

_tmp=$(mktemp -d) || exit 1
# git archive, not a worktree: this must be a pristine baseline tree that no
# amount of uncommitted work in the current checkout can influence.
if ! git archive "$_base" | tar -x -C "$_tmp"; then
  printf 'FAIL: could not export %s\n' "$_base"
  rm -rf "$_tmp"
  exit 1
fi

# The added test file is copied into the export below, because the claim being
# measured is "these assertions fail against the BASE CODE" -- not "this file
# existed then". A library the added tests source is the same kind of thing:
# leave it out and the test aborts on a missing include, having asserted
# nothing, which the gate would report as an empty baseline rather than as the
# missing helper it is. So the branch's test helpers travel with it.
for _lib in $_libs; do
  [ -f "$_lib" ] || continue
  cp "$_lib" "$_tmp/$_lib"
done

for _f in $_files; do
  if [ ! -f "$_f" ]; then
    printf 'FAIL: %s was added since the base but is not present now\n' "$_f"
    _fail=1
    continue
  fi
  cp "$_f" "$_tmp/$_f"
  chmod +x "$_tmp/$_f"

  # Status is irrelevant here; the ASSERTION LINES are the measurement. Both
  # runs are captured before anything trims them.
  _cur=$(sh "$_f" 2>&1)
  _base_out=$( cd "$_tmp" && sh "$_f" 2>&1 )

  _cur_n=$(printf '%s\n' "$_cur" | grep -cE '^(PASS|FAIL)' || true)
  _base_pass=$(printf '%s\n' "$_base_out" | grep -c '^PASS' || true)
  _base_fail=$(printf '%s\n' "$_base_out" | grep -c '^FAIL' || true)

  # The hazard is a file that ABORTS on the baseline: a test using `set -e`
  # stops at its first failing command on a tree lacking the feature, emits
  # almost nothing, and a gate counting only passes would bless it. So
  # completion is asserted directly, via a sentinel the file prints last.
  #
  # Counting is NOT usable in its place: assertions legitimately nest inside
  # preconditions (is the resolver defined, does the patch file exist), and on a
  # tree lacking the feature the precondition reports one failure where it
  # guards several — correct behaviour that a count would read as an abort.
  _base_done=$(printf '%s\n' "$_base_out" | grep -c '^DONE:' || true)

  if [ "$_cur_n" -eq 0 ]; then
    printf 'FAIL: %s made no assertions on the current tree\n' "$_f"
    _fail=1
  elif [ "$_base_pass" -ne 0 ]; then
    printf 'FAIL: %s has %s assertion(s) passing on the base — they cannot be\n' "$_f" "$_base_pass"
    printf '      detecting the change they claim to guard. Offenders:\n'
    printf '%s\n' "$_base_out" | grep '^PASS' | sed 's/^/        /'
    _fail=1
  elif [ "$_base_fail" -eq 0 ]; then
    printf 'FAIL: %s asserted nothing at all on the base\n' "$_f"
    _fail=1
  elif [ "$_base_done" -eq 0 ]; then
    printf 'FAIL: %s did not run to completion on the base — no DONE sentinel, so\n' "$_f"
    printf '      the assertions after the abort point are unproven. Tail:\n'
    printf '%s\n' "$_base_out" | tail -3 | sed 's/^/        /'
    _fail=1
  else
    printf 'PASS: %s — %s assertion(s) here, %s failing on the base, ran to completion\n' \
      "$_f" "$_cur_n" "$_base_fail"
  fi
done

rm -rf "$_tmp"
exit "$_fail"
