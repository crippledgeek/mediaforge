#!/bin/sh
# The suite does not read — or write — the developer's build tree (#55).
#
# mediaforge derives DISTDIR and PREFIX from the invocation directory, so a test
# that `cd`s to the repo root and calls ./mediaforge.sh gets the repo's own
# workspace/ as $PREFIX. Eight test files did, which made the suite's verdict a
# function of local build state rather than of the tree under test. The
# mixed-debug-level guard (#53) is where that stopped being latent: on a machine
# carrying a --debug=full workspace, a dry run of a non-debug build is refused
# before it reaches the assertion under test, and the suite fails for a reason
# unrelated to anything the branch changed.
#
# Two assertions, one static and one behavioural, because neither alone is the
# claim. The grep says no test NAMES the repo-root invocation; it cannot say
# that a test which routes around the helper some other way is independent. The
# poisoned-tree run says the tests actually survive a hostile workspace; it
# cannot say a NEW test won't reintroduce the coupling in a form that happens
# not to fail today. Together they cover both directions.
#
# The population is DERIVED, not listed. A hand-maintained list of "the eight
# affected files" is a thing to remember, and the next test to shell out to
# mediaforge would be absent from it with nothing to say so.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"

# Anything below this and the derivation has stopped finding the files it is
# about, which would make both assertions pass having measured nothing. Eight is
# the count #55 enumerated; the floor is a floor, not a pin, so adding a ninth
# invoker is not a failure.
_MIN_INVOKERS=8

# A mediaforge INVOCATION, in either spelling: `./mediaforge.sh <subcommand>`
# (the coupled form) or `_mf <subcommand>` (through tests/lib-scratch.sh). The
# trailing [a-z] is what separates an invocation from a mention: tests/
# comment-citations.sh passes ./mediaforge.sh to grep as a FILE argument, and
# the next thing on that line is ./lib/*.sh rather than a subcommand.
#
# Comments are stripped first. Four files name `./mediaforge.sh` in explanatory
# prose — including tests/lib-scratch.sh, whose whole subject is why the form is
# wrong — and matching those would fail the static assertion with a message
# asserting the opposite of the truth.
_INVOKE_RE='(\./mediaforge\.sh|_mf)[[:space:]]+[a-z]'

# tests/lib-*.sh are sourced libraries, not runnable tests, and this file is
# excluded from its own population: it RUNS the files it selects, so selecting
# itself would recurse until the process table says otherwise.
_invokers=''
for _f in tests/*.sh; do
  case "$_f" in
    tests/lib-*.sh | tests/workspace-independence.sh) continue ;;
  esac
  if sed 's/#.*//' "$_f" | grep -qE "$_INVOKE_RE"; then
    _invokers="$_invokers $_f"
  fi
done

_n=0
for _f in $_invokers; do _n=$((_n + 1)); done
if [ "$_n" -lt "$_MIN_INVOKERS" ]; then
  # Reported once, and both assertions are then skipped rather than run against
  # a population that cannot support them.
  _bad invoker-population-found "found $_n mediaforge-invoking test file(s), want >= $_MIN_INVOKERS"
else

# ─── static: no test invokes mediaforge from the repo root ──────────────────
_offenders=''
for _f in $_invokers; do
  if sed 's/#.*//' "$_f" | grep -qE '\./mediaforge\.sh[[:space:]]+[a-z]'; then
    _offenders="$_offenders $_f"
  fi
done
if [ -z "$_offenders" ]; then
  _pass no-test-invokes-mediaforge-from-the-repo-root
else
  _bad no-test-invokes-mediaforge-from-the-repo-root \
    "these run mediaforge with the repo as TOPDIR, so \$PREFIX is the developer's workspace:$_offenders"
fi

# ─── behavioural: a hostile workspace changes no verdict ────────────────────
# A symlink farm, not a copy: every entry of the repo except the two working
# directories is linked into a temporary root, and a poisoned workspace/ is put
# there instead. A test run from that root computes $ROOT as the farm (cd -L
# resolves the trailing .. textually, so the symlinked tests/ does not leak the
# real path back in), and anything it reads by repo-relative path still reaches
# the real file through the link.
#
# The poison is the state the issue reported: a debug level the next build does
# not ask for, plus a stamp, which is what arms the guard. Any workspace state a
# test is sensitive to would do; this one is the state that was on the reporter's
# machine, and it is the cheapest to construct.
_tree=$(mktemp -d) || exit 1
trap 'rm -rf "$_tree"' EXIT
for _e in "$_root"/*; do
  case "${_e##*/}" in
    workspace | packages) continue ;;
  esac
  ln -s "$_e" "$_tree/${_e##*/}"
done
mkdir -p "$_tree/workspace/.stamps"
printf 'full' > "$_tree/workspace/.debug-level"
: > "$_tree/workspace/.stamps/poison-1"

_broken=''
for _f in $_invokers; do
  if ! sh "$_tree/$_f" >/dev/null 2>&1; then
    _broken="$_broken $_f"
  fi
done
if [ -z "$_broken" ]; then
  _pass suite-survives-a-poisoned-workspace
else
  _bad suite-survives-a-poisoned-workspace \
    "failed against a workspace/ built at --debug=full:$_broken"
fi

fi

# Completion sentinel, read by tests/oracle-baseline.sh: it distinguishes
# "asserted and failed", which is what the gate wants to see from a file
# measuring a change, from "aborted before asserting", which it exists to catch.
printf 'DONE: workspace independence\n'
exit "$_fail"
