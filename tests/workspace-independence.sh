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
# Three assertions, because the header makes three claims and no one check
# carries all of them. The grep says no test NAMES the repo-root invocation; it
# cannot say that a test routing around the helper some other way is
# independent. The poisoned run says the tests survive a hostile workspace; it
# cannot see a write, because the guard it arms aborts the build before
# mediaforge creates anything. The clean run is the only one that can witness a
# write, and it is the cheapest of the three.
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
# about, which would make every assertion pass having measured nothing. Eight is
# the count #55 enumerated; the floor is a floor, not a pin, so adding a ninth
# invoker is not a failure.
_MIN_INVOKERS=8

# A mediaforge INVOCATION, in either spelling: `./mediaforge.sh <subcommand>`
# (the coupled form) or `_mf <subcommand>` (through tests/lib-scratch.sh). The
# trailing [a-z] is what separates an invocation from a mention: tests/
# comment-citations.sh passes ./mediaforge.sh to grep as a FILE argument, and
# the next thing on that line is ./lib/*.sh rather than a subcommand.
_INVOKE_RE='(\./mediaforge\.sh|_mf)[[:space:]]+[a-z]'
_ROOT_INVOKE_RE='\./mediaforge\.sh[[:space:]]+[a-z]'

# Comments are stripped before matching. Files in this population name
# ./mediaforge.sh in explanatory prose — tests/checksum-verification.sh and
# tests/install-manifest-reconcile.sh both do — and matching a mention would
# fail the static assertion with a message asserting the opposite of the truth.
#
# Defined once and used by both greps below. They ask different questions of the
# same two-step (strip, then match), and the stripping is the half that is easy
# to get subtly right in one place and wrong in the other.
_matches() { # file  ERE
  sed 's/#.*//' "$1" | grep -qE "$2"
}

# tests/lib-*.sh are sourced libraries, not runnable tests, and this file is
# excluded from its own population: it RUNS the files it selects, so selecting
# itself would recurse until the process table says otherwise.
_invokers=''
for _f in tests/*.sh; do
  case "$_f" in
    tests/lib-*.sh | tests/workspace-independence.sh) continue ;;
  esac
  if _matches "$_f" "$_INVOKE_RE"; then
    _invokers="$_invokers $_f"
  fi
done

_n=0
for _f in $_invokers; do _n=$((_n + 1)); done
if [ "$_n" -lt "$_MIN_INVOKERS" ]; then
  # Reported once, and the assertions are then skipped rather than run against a
  # population that cannot support them.
  _bad invoker-population-found "found $_n mediaforge-invoking test file(s), want >= $_MIN_INVOKERS"
else

# ─── static: no test invokes mediaforge from the repo root ──────────────────
_offenders=''
for _f in $_invokers; do
  if _matches "$_f" "$_ROOT_INVOKE_RE"; then
    _offenders="$_offenders $_f"
  fi
done
if [ -z "$_offenders" ]; then
  _pass no-test-invokes-mediaforge-from-the-repo-root
else
  _bad no-test-invokes-mediaforge-from-the-repo-root \
    "these run mediaforge with the repo as TOPDIR, so \$PREFIX is the developer's workspace:$_offenders"
fi

# ─── behavioural: run the suite somewhere it can be watched ─────────────────
# A symlink farm, not a copy: every non-hidden entry of the repo except the two
# working directories is linked into a temporary root. Dotfiles are left out
# because a POSIX glob does not match them, which happens to be what we want —
# .git in particular has no business being reachable from a tree whose whole
# purpose is to be written to and thrown away.
#
# A test run from that root computes $ROOT as the farm (cd -L resolves the
# trailing .. textually, so the symlinked tests/ does not leak the real path
# back in), and anything it reads by repo-relative path still reaches the real
# file through the link. What it CANNOT reach is the real workspace/, which is
# the property under test: whatever a coupled test does to its TOPDIR, it does
# to the farm, where we can look at it afterwards.
_farm() { # dir
  mkdir -p "$1"
  for _e in "$_root"/*; do
    case "${_e##*/}" in
      workspace | packages) continue ;;
    esac
    ln -s "$_e" "$1/${_e##*/}"
  done
}

_tree=$(mktemp -d) || exit 1
_clean=$(mktemp -d) || exit 1
trap 'rm -rf "$_tree" "$_clean"' EXIT
_farm "$_tree"
_farm "$_clean"

# The poison is the state the issue reported: a debug level the next build does
# not ask for, plus a stamp, which is what arms the guard. Both halves are
# required — the guard fires only when .stamps is non-empty — and that is also
# why the poisoned farm cannot carry the write assertion below: it aborts the
# build before DISTDIR or the stamp directory are created, so on a coupled tree
# it witnesses nothing being written. Measured, not assumed.
mkdir -p "$_tree/workspace/.stamps"
printf 'full' > "$_tree/workspace/.debug-level"
: > "$_tree/workspace/.stamps/poison-1"

# Snapshotted rather than enumerated. The first draft listed the artifacts a
# coupled test would leave -- .logs, .pc-skip-queue, .mediaforge-choices -- and
# was wrong on the day it was written: mediaforge also writes .extra_cflags,
# .extra_ldflags and .debug-level at the top of $PREFIX, and a new file under
# .stamps is exactly what tests/negative.sh plants. A list of names here is the
# same hand-maintained list this file's header declines to keep for its
# population, for the same reason: it rots with nothing to say so.
_wsbefore=$(find "$_tree/workspace" | sort)

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

# ─── behavioural: nothing is written into the tree the suite runs from ──────
# The read half above is not the whole claim. tests/negative.sh PLANTS stamps
# rather than only reading them, and its `mkdir -p workspace/.stamps` created
# that directory in repos that had never been built; a regression that re-plants
# them in $ROOT exits 0 and the poisoned run stays green.
#
# Two trees, for two different reasons. The clean farm runs ONE file, and it is
# the file that writes on its own account — it is the only one whose absence of
# writes is a claim about the test rather than about mediaforge, and it is also
# the only tree in which a coupled test gets far enough to write at all, so it
# is what makes this assertion fail on a tree that has the defect. The poisoned
# farm is then checked too, at no extra cost: the whole population has just run
# there, so a write by any OTHER invoker is caught even though that tree cannot
# be the oracle.
#
# packages/ is the sharper half. Neither farm links it, so its existence is
# unambiguously a test having run mediaforge with the farm as TOPDIR.
# The pick is bound to the derived population rather than merely named. If
# tests/negative.sh is renamed, split or dropped, `sh` fails, nothing is ever
# written into the clean farm, and `|| true` swallows the only signal -- the
# assertion would pass having run nothing, which is the vacuity the floor above
# exists to prevent.
_writer=tests/negative.sh
_wrote=''
case " $_invokers " in
  *" $_writer "*)
    sh "$_clean/$_writer" >/dev/null 2>&1 || true
    ;;
  *)
    _wrote="$_wrote ($_writer left the derived population, so nothing was run)"
    ;;
esac
[ -e "$_clean/packages" ] && _wrote="$_wrote $_clean/packages"
[ -e "$_clean/workspace" ] && _wrote="$_wrote $_clean/workspace"
[ -e "$_tree/packages" ] && _wrote="$_wrote $_tree/packages"
# The poisoned farm's workspace/ is ours, so only a CHANGE to it counts.
[ "$(find "$_tree/workspace" | sort)" = "$_wsbefore" ] ||
  _wrote="$_wrote $_tree/workspace(modified)"
if [ -z "$_wrote" ]; then
  _pass suite-writes-nothing-into-the-tree-it-runs-from
else
  _bad suite-writes-nothing-into-the-tree-it-runs-from \
    "a test used its own root as TOPDIR and left:$_wrote"
fi

fi

# Completion sentinel, read by tests/oracle-baseline.sh: it distinguishes
# "asserted and failed", which is what the gate wants to see from a file
# measuring a change, from "aborted before asserting", which it exists to catch.
printf 'DONE: workspace independence\n'
exit "$_fail"
