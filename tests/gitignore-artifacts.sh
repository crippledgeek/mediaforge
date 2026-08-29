#!/bin/sh
# The agent-artifact ignore patterns must actually BITE.
#
# `.gitignore` fails silently. A pattern that matches nothing looks identical in
# `git status` to one that works — the artifact simply shows up as untracked and
# someone commits it. The failure mode this guards is not "the line is missing",
# which a reader would notice, but "the line is there and does nothing":
#
#   * a trailing comment becomes part of the pattern, because git honours '#'
#     only at the START of a line, so `docs/  # scratch` matches a path that
#     literally contains those spaces and the hash — i.e. nothing;
#   * a leading slash silently narrows a pattern to the repo root, so
#     `/CLAUDE.md` stops covering a per-directory one;
#   * a new tool's output directory is simply never added, which is what this
#     file was written for: graphify-out/ was absent while every sibling
#     (.claude/, .superpowers/, .cursor/) was present.
#
# Asked of git rather than of the file's text: `git check-ignore` answers with
# the rule that actually matched, so a pattern that is present but inert is
# reported as a miss. Grepping .gitignore for the string would call that a pass.
#
# Two assertions, and the first is compound deliberately.
# tests/oracle-baseline.sh requires that no assertion in a newly added file
# passes on the merge base, and every pattern here except graphify-out/ already
# bit there — so the whole probe set is asserted together, with the one the base
# gets wrong carrying it. That is the only pairing available, and it is the
# honest shape: the claim is "the artifact set is covered", not "each line
# exists".
#
# The second check is the complement — nothing matching those names is TRACKED.
# It is paired for the same reason: the base's tree was clean too, and it runs
# only inside a real checkout (see below).
#
# The first check builds a SCRATCH repo from this tree's .gitignore rather than
# asking the enclosing one. Two reasons, and the second is load-bearing:
#
#  * it isolates the subject. The answer is about the .gitignore file under
#    test, not about whatever the ambient repo's excludesFile, .git/info/exclude
#    or per-directory ignores happen to add — so a pattern that only "works"
#    because the developer's global config covers it is still reported as a miss.
#  * tests/oracle-baseline.sh runs this file against a `git archive` EXPORT of
#    the merge base, which is a plain directory with no .git at all. The first
#    version of this file asked the enclosing repo, found none, and skipped —
#    the gate correctly rejected it as "asserted nothing at all on the base".
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest — and the
# baseline gate depends on that, since a file that aborts early cannot prove the
# assertions after the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"

if ! command -v git >/dev/null 2>&1; then
  printf 'SKIP: needs git\n'
  printf 'DONE: gitignore-artifacts\n'
  exit 0
fi

# Scratch repo holding only this tree's .gitignore. core.excludesFile is pointed
# at nothing so a developer's global ignores cannot answer for the repo's.
_scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$_scratch"' EXIT
_cleanup_on_signal
git init -q "$_scratch" 2>/dev/null || { printf 'SKIP: cannot init a scratch repo\n'
  printf 'DONE: gitignore-artifacts\n'; exit 0; }
cp .gitignore "$_scratch/.gitignore" 2>/dev/null || true

_ignored() {
  git -C "$_scratch" -c core.excludesFile=/dev/null check-ignore -q "$1"
}

# One probe path per artifact family. Paths that do NOT exist on disk are fine —
# check-ignore answers about the path, not about the file.
_probes='CLAUDE.md
CLAUDE.local.md
AGENTS.md
GEMINI.md
.claude/settings.json
.claude/rules/x.md
.superpowers/briefs/x.md
graphify-out/graph.json
docs/plan.md
sub/dir/CLAUDE.md'

_uncovered=''
while IFS= read -r _p; do
  [ -z "$_p" ] && continue
  _ignored "$_p" || _uncovered="$_uncovered $_p"
done <<EOF
$_probes
EOF

if [ -z "$_uncovered" ]; then
  _pass every-artifact-path-ignored
else
  _bad every-artifact-path-ignored "not ignored:$_uncovered"
fi

# The complement. check-ignore says a path WOULD be ignored; it says nothing
# about what is already in the index, and an artifact committed before the
# pattern existed stays tracked forever — .gitignore does not untrack.
# Only inside a real checkout: the baseline export has no index to read, and an
# assertion that cannot run there must not report either way.
if git rev-parse --git-dir >/dev/null 2>&1; then
  _tracked=$(git ls-files \
    | grep -iE 'CLAUDE\.md|AGENTS\.md|GEMINI\.md|^docs/|/docs/|\.superpowers|\.claude(-mem)?/|graphify-out' \
    || true)
  if [ -n "$_tracked" ]; then
    _bad no-artifact-tracked-or-addable "tracked agent artifact(s): $_tracked"
  elif [ -n "$_uncovered" ]; then
    # Nothing is tracked, but a gap in the patterns means the second half of the
    # claim ("none could be added unnoticed") is not true. Say which half failed
    # — the earlier version printed an empty tracked-list here and read as though
    # it had found something.
    _bad no-artifact-tracked-or-addable \
      "nothing tracked, but these could be added unnoticed:$_uncovered"
  else
    _pass no-artifact-tracked-or-addable
  fi
fi

printf 'DONE: gitignore-artifacts\n'
exit "$_fail"
