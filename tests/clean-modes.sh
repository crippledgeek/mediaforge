#!/bin/sh
# Pins which of the two working directories `clean` is allowed to remove.
#
# $PREFIX and $DISTDIR cost different things to replace, and only one of them is
# the tool's to reconstruct. A build tree is rebuildable from local state at the
# price of CPU time; the tarball cache is a set of files already checked against
# their .hash sidecars, and refilling it depends on every upstream still serving
# the same bytes at that minute. mediaforge neither controls that nor can retry
# its way out of it — GH-70 is the incident: a full clean discarded the cache,
# code.videolan.org answered one archive path with a bot challenge, and the
# pipeline was blocked on a file it had held a verified copy of ten minutes
# earlier (GH-71).
#
# So the flag, not the tree, decides. That is the assertion `mode-comes-from-the-
# flag-not-the-tree` exists for: an implementation that removes "whatever is
# there" passes every other case in this file while being exactly the defect —
# on a tree whose build had already been cleaned, the only thing left to find is
# the cache.
#
# Every authoritative build system draws the line in this place. ports(7):
# `clean` "Remove the expanded source code", `distclean` "Remove the port's
# distfiles and perform the clean target". port-clean(1) makes --work the
# default and --dist a separate request. makepkg(8) has no option that touches
# SRCDEST at all. The GNU standards put the fetched distribution BELOW the floor
# of even distclean ("should leave only the files that were in the
# distribution"), and require the one target that deletes hard-to-rebuild things
# to announce itself before acting — which is what `all-says-what-it-discards`
# holds --all to.
#
# The vacuity guard below follows tests/storage-guard.sh: on the merge base
# `clean` removes both directories, so three of these assertions (the two
# removals and the missing-directory case) would PASS there while the defect is
# present, and tests/oracle-baseline.sh requires every assertion to fail on a
# tree without the behaviour. The probe is the behaviour itself rather than a
# function name, so the file cannot go green against an implementation that
# merely renamed something.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
# shellcheck source=tests/lib-scratch.sh
. "$ROOT/tests/lib-scratch.sh"

trap '_scratch_cleanup' EXIT
_cleanup_on_signal

# One run, one recording. Each case wants a TREE IN A KNOWN STATE, so the
# scratch TOPDIR is rebuilt per run rather than shared: a case that asserts what
# survives cannot start from what the previous case left.
#
# `seed` says which directories exist before the run, which is the axis
# `mode-comes-from-the-flag-not-the-tree` varies. The tarball is a real file
# with content, so "the directory still exists" and "the bytes are still there"
# are distinguishable — an implementation that removed the files and left the
# empty directory would otherwise read as a pass.
_clean_run() { # tag  seed(both|cache-only|workspace-only)  [args...]
  _tag=$1; _seed=$2; shift 2
  _scratch_cleanup
  _scratch_init "$ROOT"
  case "$_seed" in
    both|cache-only)
      mkdir -p "$_MF_SCRATCH/packages"
      printf 'tarball bytes\n' > "$_MF_SCRATCH/packages/libfoo-1.0.tar.xz"
      ;;
  esac
  case "$_seed" in
    both|workspace-only)
      mkdir -p "$_MF_SCRATCH/workspace/lib"
      printf 'built artifact\n' > "$_MF_SCRATCH/workspace/lib/libfoo.a"
      ;;
  esac
  _rc=0
  _out=$(_mf clean "$@" 2>&1) || _rc=$?
  # if/else, not `[ ... ] && _x=present`. This file runs under `set -e`, where a
  # test that finds nothing is the failing last command of its line and takes
  # the script down before any assertion is reported — in exactly the case the
  # assertion exists to describe.
  if [ -f "$_MF_SCRATCH/packages/libfoo-1.0.tar.xz" ]; then _cache=present; else _cache=absent; fi
  if [ -f "$_MF_SCRATCH/workspace/lib/libfoo.a" ]; then _tree=present; else _tree=absent; fi
  _said=$(printf '%s' "$_out" | tr '\n' ' ')
}

# --- the probe, which is also the first assertion ---------------------------
_clean_run default both
if [ "$_cache" = present ]; then
  _pass default-keeps-the-tarball-cache
  _have=true
else
  _bad default-keeps-the-tarball-cache "a bare 'clean' removed packages/ (rc=$_rc): $_said"
  _have=false
fi

if [ "$_have" = false ]; then
  for _a in default-removes-the-build-tree all-removes-both \
            default-succeeds-with-no-cache-directory \
            mode-comes-from-the-flag-not-the-tree unknown-option-is-rejected \
            all-says-what-it-discards default-says-what-it-kept \
            help-names-the-build-tree help-names-the-cache; do
    _bad "$_a" "the workspace-only default is absent — claim would be vacuous"
  done
  printf 'DONE: clean-modes\n'
  exit "$_fail"
fi

# Keeping the cache is only half of it: a `clean` that removed nothing would
# satisfy the assertion above and be useless.
if [ "$_tree" = absent ] && [ "$_rc" -eq 0 ]; then
  _pass default-removes-the-build-tree
else
  _bad default-removes-the-build-tree "workspace/ survived a bare 'clean' (rc=$_rc): $_said"
fi

# What it kept, said out loud. The default is a behaviour CHANGE for anyone who
# has been running `clean` to reclaim disk, and the only place that reaches them
# is the output of the command they are already running.
case "$_said" in
  *packages*--all*) _pass default-says-what-it-kept ;;
  *) _bad default-says-what-it-kept "the default path did not name the cache it kept or the flag that removes it: $_said" ;;
esac

# --- the destructive form, still reachable ----------------------------------
_clean_run all both --all
if [ "$_cache" = absent ] && [ "$_tree" = absent ] && [ "$_rc" -eq 0 ]; then
  _pass all-removes-both
else
  _bad all-removes-both "--all left cache=$_cache tree=$_tree (rc=$_rc): $_said"
fi

# GNU's rule for the target that deletes what special tools are needed to
# rebuild: say so before doing it. Asserted on the words an operator would act
# on rather than on an exact sentence — this is the one output in the file whose
# wording is meant to stay editable.
case "$_said" in
  *packages*) _pass all-says-what-it-discards ;;
  *) _bad all-says-what-it-discards "--all discarded the cache without naming it: $_said" ;;
esac

# --- the tree does not choose the mode --------------------------------------
# No packages/ at all. `rm -rf` on a missing path is silent, so this is not
# about the removal — it is about a run that has nothing to fetch reporting
# success rather than tripping over the absence.
_clean_run nocache workspace-only
if [ "$_rc" -eq 0 ] && [ "$_tree" = absent ]; then
  _pass default-succeeds-with-no-cache-directory
else
  _bad default-succeeds-with-no-cache-directory "a tree with no packages/ failed the default clean (rc=$_rc, tree=$_tree): $_said"
fi

# The case the whole issue is about, and the one every other assertion here is
# blind to. A build tree that has already been cleaned leaves the cache as the
# only removable thing in the TOPDIR; an implementation that decides its mode
# from what it finds discards it, and reports success while doing so.
_clean_run cacheonly cache-only
if [ "$_cache" = present ] && [ "$_rc" -eq 0 ]; then
  _pass mode-comes-from-the-flag-not-the-tree
else
  _bad mode-comes-from-the-flag-not-the-tree "with workspace/ already gone, a bare 'clean' removed the cache (rc=$_rc): $_said"
fi

# --- an unrecognised option is not the default ------------------------------
# `clean` took no options at all before this change, so every argument reaching
# it was ignored. A typo'd --all must not silently keep the cache the operator
# asked to remove, and must not remove the tree on its way to finding that out.
_clean_run bogus both --alll
if [ "$_rc" -ne 0 ] && [ "$_cache" = present ] && [ "$_tree" = present ]; then
  _pass unknown-option-is-rejected
else
  _bad unknown-option-is-rejected "'clean --alll' exited $_rc leaving cache=$_cache tree=$_tree: $_said"
fi

# --- the help text ----------------------------------------------------------
# Both directories by name. "Remove all build artifacts" called them one thing,
# which is what made the cache a side effect rather than a decision.
_wired help-names-the-build-tree mediaforge.sh 'clean              Remove the build tree'
_wired help-names-the-cache      mediaforge.sh '--all                 Also remove'

printf 'DONE: clean-modes\n'
exit "$_fail"
