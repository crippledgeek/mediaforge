#!/bin/sh
# Pins what `clean` is allowed to remove, and what only an upstream could give
# back.
#
# The line is not "one directory each". $DISTDIR holds three kinds of entry, and
# they differ in the only way that matters here — whether restoring one needs a
# network:
#
#   reconstructible locally     $PREFIX, and the trees unpacked from an archive
#                               we still hold ($DISTDIR/<dir>/)
#   needs an upstream to answer the downloaded archives ($DISTDIR/<file>) and
#                               the git clones ($DISTDIR/<dir>/.git)
#
# GH-71 records what removing the second group as a side effect costs: a full
# clean discarded the cache, code.videolan.org answered one archive path with a
# bot challenge that minute, and the run was blocked on a file it had held a
# verified copy of ten minutes earlier. It recovered only because a verified copy
# happened to survive outside packages/. (GH-70 is the fetch-retry defect from
# the same incident, not this narrative.) x264 is cloned from that same host,
# which is why `default-keeps-git-clones` is here.
#
# So the flag, not the tree, decides. That is what `mode-comes-from-the-flag-not-
# the-tree` exists for: an implementation that removes "whatever is there"
# passes every other case in this file while being exactly the defect — on a
# tree whose build had already been cleaned, the only thing left to find is the
# cache.
#
# Every authoritative build system draws the line in this place, including the
# part this file had to be extended to cover. ports(7): `clean` "Remove the
# expanded source code", `distclean` "Remove the port's distfiles and perform the
# clean target" — so the unpacked sources go with the build tree, not with the
# archives. port-clean(1) makes --work the default and --dist a separate request
# -- distfiles ALONE, which is why our union flag is --all and not --dist; see
# lib/cleanup.sh's header.
# makepkg(8) has no option that touches SRCDEST at all. GNU's distclean "should
# leave only the files that were in the distribution" -- read here as putting the
# fetched distribution below even distclean's floor, which is our INFERENCE from
# what that sentence preserves rather than a rule GNU states. What GNU does state
# is that the target deleting hard-to-rebuild things SHOULD start by announcing
# itself (a convention, not a mandate), and that is what
# `all-says-what-it-discards-before-discarding-it` holds --all to.
#
# The vacuity guard below follows tests/storage-guard.sh: on the merge base
# `clean` removes both directories, so several of these assertions (the removals
# and the missing-directory case) would PASS there while the defect is present,
# and tests/oracle-baseline.sh requires every assertion to fail on a tree without
# the behaviour. The probe is the behaviour itself rather than a function name,
# so the file cannot go green against an implementation that merely renamed
# something.
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
_clean_run() { # seed(both|cache-only|workspace-only)  [args...]
  _seed=$1; shift
  _scratch_cleanup
  _scratch_init "$ROOT"
  case "$_seed" in
    both|cache-only)
      # The three kinds of entry $DISTDIR really holds (lib/download.sh writes
      # all three): the downloaded archive, the tree it was unpacked into, and a
      # git clone. Seeding only the first would leave the default's treatment of
      # the other two unmeasured -- which is how the unpacked trees came to be
      # kept by a change whose own cited precedent removes them.
      mkdir -p "$_MF_SCRATCH/packages"
      printf 'tarball bytes\n' > "$_MF_SCRATCH/packages/libfoo-1.0.tar.xz"
      mkdir -p "$_MF_SCRATCH/packages/libfoo-1.0"
      printf 'unpacked source\n' > "$_MF_SCRATCH/packages/libfoo-1.0/configure"
      # .git is what tells a clone from an unpacked archive, so the fixture has
      # to carry one or it is a test of the wrong predicate.
      mkdir -p "$_MF_SCRATCH/packages/libbar/.git"
      printf 'clone\n' > "$_MF_SCRATCH/packages/libbar/README"
      # A symlinked entry pointing OUTSIDE packages/. `rm -rf` on a symlink
      # unlinks it without recursing, so the target was never in danger -- what
      # the skip protects is the link itself, and only a fixture that keeps the
      # two distinguishable can tell the skip from its absence.
      mkdir -p "$_MF_SCRATCH/outside"
      printf 'not ours\n' > "$_MF_SCRATCH/outside/keepme"
      ln -s "$_MF_SCRATCH/outside" "$_MF_SCRATCH/packages/linked"
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
  if [ -f "$_MF_SCRATCH/packages/libfoo-1.0/configure" ]; then _src=present; else _src=absent; fi
  if [ -f "$_MF_SCRATCH/packages/libbar/README" ]; then _clone=present; else _clone=absent; fi
  if [ -L "$_MF_SCRATCH/packages/linked" ]; then _link=present; else _link=absent; fi
  if [ -f "$_MF_SCRATCH/outside/keepme" ]; then _target=present; else _target=absent; fi
  _said=$(printf '%s' "$_out" | tr '\n' ' ')
}

# --- the probe, which is also the first assertion ---------------------------
_clean_run both
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
            bare-operand-is-rejected end-of-options-does-not-smuggle-past-the-parser \
            default-removes-the-unpacked-sources default-keeps-git-clones \
            default-leaves-symlinked-entries-alone \
            all-says-what-it-discards-before-discarding-it default-says-what-it-kept \
            clone-predicate-has-one-definition \
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

# ports(7)'s `clean` is "Remove the expanded source code", and the unpacked trees
# live in $DISTDIR beside the archives they came from. A default that keeps them
# reclaims almost nothing -- they are the bulk of that directory -- while still
# calling itself a clean.
if [ "$_src" = absent ]; then
  _pass default-removes-the-unpacked-sources
else
  _bad default-removes-the-unpacked-sources "packages/libfoo-1.0/ survived a bare 'clean': $_said"
fi

# A clone is not an unpacked archive: re-creating it needs the forge, and x264 is
# cloned from the host whose bot challenge caused GH-71 in the first place. The
# predicate is .git, so this is also what stops the prune from being "remove
# every directory".
if [ "$_clone" = present ]; then
  _pass default-keeps-git-clones
else
  _bad default-keeps-git-clones "a bare 'clean' removed packages/libbar/, a git clone: $_said"
fi

# The symlink skip, which nothing pinned until a mutation went unnoticed:
# dropping `[ ! -L "$1" ]` from the prune left every other assertion green. An
# entry that is a symlink is left alone whatever it points at -- deciding that
# is not cleanup's business, and the count would otherwise call a link an
# unpacked source tree.
if [ "$_link" = present ] && [ "$_target" = present ]; then
  _pass default-leaves-symlinked-entries-alone
else
  _bad default-leaves-symlinked-entries-alone "after a bare 'clean' the link is $_link and its target is $_target; both should be present"
fi

# What it kept, said out loud. The default is a behaviour CHANGE for anyone who
# has been running `clean` to reclaim disk, and the only place that reaches them
# is the output of the command they are already running.
case "$_said" in
  *packages*--all*) _pass default-says-what-it-kept ;;
  *) _bad default-says-what-it-kept "the default path did not name the cache it kept or the flag that removes it: $_said" ;;
esac

# --- the destructive form, still reachable ----------------------------------
_clean_run both --all
if [ "$_cache" = absent ] && [ "$_tree" = absent ] && [ "$_rc" -eq 0 ]; then
  _pass all-removes-both
else
  _bad all-removes-both "--all left cache=$_cache tree=$_tree (rc=$_rc): $_said"
fi

# GNU's convention for the target that deletes what special tools are needed to
# rebuild: say so BEFORE doing it. The order is the whole claim, and matching a
# flattened blob cannot see it -- a warning printed after the rm would satisfy
# `*packages*` identically. So this reads line NUMBERS out of the unflattened
# output.
#
# What it pins is warning-before-"Removed the build tree", which is the first
# thing full_cleanup does after warning; the `rm -rf "$DISTDIR"` is later still.
# A proxy, and a tight one -- there is no point between them for a removal to
# hide.
_warn_at=$(printf '%s\n' "$_out" | grep -n 'Also removing' | head -1 | cut -d: -f1 || true)
_rm_at=$(printf '%s\n' "$_out" | grep -n 'Removed the build tree' | head -1 | cut -d: -f1 || true)
if [ -z "$_warn_at" ]; then
  _bad all-says-what-it-discards-before-discarding-it "--all discarded the cache without naming it: $_said"
elif [ -z "$_rm_at" ]; then
  _bad all-says-what-it-discards-before-discarding-it "--all never reported removing the build tree, so the order could not be read: $_said"
elif [ "$_warn_at" -lt "$_rm_at" ]; then
  _pass all-says-what-it-discards-before-discarding-it
else
  _bad all-says-what-it-discards-before-discarding-it "the warning came at line $_warn_at, after the removal at line $_rm_at: $_said"
fi

# --- the tree does not choose the mode --------------------------------------
# No packages/ at all. `rm -rf` on a missing path is silent, so this is not
# about the removal — it is about a run that has nothing to fetch reporting
# success rather than tripping over the absence.
_clean_run workspace-only
if [ "$_rc" -eq 0 ] && [ "$_tree" = absent ]; then
  _pass default-succeeds-with-no-cache-directory
else
  _bad default-succeeds-with-no-cache-directory "a tree with no packages/ failed the default clean (rc=$_rc, tree=$_tree): $_said"
fi

# The case the whole issue is about, and the one every other assertion here is
# blind to. A build tree that has already been cleaned leaves the cache as the
# only removable thing in the TOPDIR; an implementation that decides its mode
# from what it finds discards it, and reports success while doing so.
_clean_run cache-only
if [ "$_cache" = present ] && [ "$_rc" -eq 0 ]; then
  _pass mode-comes-from-the-flag-not-the-tree
else
  _bad mode-comes-from-the-flag-not-the-tree "with workspace/ already gone, a bare 'clean' removed the cache (rc=$_rc): $_said"
fi

# --- an unrecognised option is not the default ------------------------------
# `clean` took no options at all before this change, so every argument reaching
# it was ignored. A typo'd --all must not silently keep the cache the operator
# asked to remove, and must not remove the tree on its way to finding that out.
_clean_run both --alll
if [ "$_rc" -ne 0 ] && [ "$_cache" = present ] && [ "$_tree" = present ]; then
  _pass unknown-option-is-rejected
else
  _bad unknown-option-is-rejected "'clean --alll' exited $_rc leaving cache=$_cache tree=$_tree: $_said"
fi

# A bare operand, which is the deliberate divergence from cmd_install and
# cmd_uninstall (they end their loops with `*) break` because they take one).
# `clean` takes no operands, so anything that is not a flag is a mistake worth
# reporting rather than ignoring.
_clean_run both foo
if [ "$_rc" -ne 0 ] && [ "$_cache" = present ] && [ "$_tree" = present ]; then
  _pass bare-operand-is-rejected
else
  _bad bare-operand-is-rejected "'clean foo' exited $_rc leaving cache=$_cache tree=$_tree: $_said"
fi

# `--` was an arm in the first version of this parser, copied from cmd_install
# where it earns its place. Here it meant "stop reading, ignore the rest", so
# `clean -- --all` kept the cache, said nothing, and exited 0 -- the exact case
# the parser's own comment argued must not happen. A review found it by running
# it; nothing in this file could see it.
#
# Either behaviour is defensible: honour the flag, or refuse the argument. What
# is not defensible is silently doing neither, so this accepts both and rejects
# only the silent keep.
_clean_run both -- --all
if [ "$_rc" -ne 0 ] && [ "$_cache" = present ]; then
  _pass end-of-options-does-not-smuggle-past-the-parser
elif [ "$_rc" -eq 0 ] && [ "$_cache" = absent ]; then
  _pass end-of-options-does-not-smuggle-past-the-parser
else
  _bad end-of-options-does-not-smuggle-past-the-parser "'clean -- --all' exited $_rc and left cache=$_cache -- neither refused nor honoured: $_said"
fi

# --- the coupling nothing else would notice ---------------------------------
# Cleanup decides "is this a clone" with the same test fetch_git uses to decide
# "is this destination reusable". They have to agree: if cleanup kept a shape
# fetch_git rejects, the kept directory would be deleted by the next build
# anyway; if cleanup pruned a shape fetch_git reuses, a bare `clean` would cost a
# re-clone. Neither is visible from either file alone, and both read correctly on
# their own.
#
# So the assertion is that there is ONE definition and no private copies -- not
# that two greps happen to match. The first version of this assertion counted
# occurrences per file, and a THIRD copy inside describe_cached_assets satisfied
# the count while the prune's own predicate drifted: mutating `-d` to `-e` left
# this green. Convergence is the only form of the claim a grep can hold.
# Counted through one `cat` rather than per-file arithmetic. The first version
# summed `grep -c` across three files and passed `--no-filename` AFTER `--`,
# where it is an operand and not an option: grep then looked for a file by that
# name, printed filename-prefixed counts for the real ones, and the
# `paste -sd+ | bc` behind it produced nothing at all. So the assertion reported
# a failure it had not measured -- the shape this whole file exists to prevent,
# in its own code.
_defs=$(_code_only lib/utils.sh | grep -c '^mf_is_git_clone()' || true)
# Every file in lib/, and a pattern that survives the spellings a regrowth would
# plausibly use. Naming three files could not see a fourth growing a copy, and
# `[$][A-Za-z0-9_]*` missed both `${_entry}/.git` (braces) and
# `$DISTDIR/$_dir/.git` (two expansions, which is download.sh's house style for
# paths) -- measured, not assumed. Matching any quoted path ending in /.git
# catches all four.
# Comments STRIPPED before counting, both ways round. `_raw` reads high if a
# comment illustrates the raw form -- mf_is_git_clone's own comment argues -d
# versus -e and is one edit from quoting it -- and that reports a copy that does
# not exist. `_users` is the dangerous direction: delete a real call site, leave
# a comment quoting the call, and the count is preserved while the caller is
# gone. This repo quotes calls in prose as a habit, and twice on this branch a
# grep over unstripped source measured what a file SAYS. _lib_code is in
# tests/lib-assert.sh, because this file and tests/output-and-startup-hygiene.sh
# both needed it.
_raw=$(_lib_code | grep -c -- '-d "[^"]*/[.]git"' || true)
_users=$(_lib_code | grep -c 'mf_is_git_clone "' || true)
if [ "$_defs" != 1 ]; then
  _bad clone-predicate-has-one-definition "expected exactly one mf_is_git_clone definition in lib/utils.sh, found $_defs"
elif [ "$_raw" != 1 ]; then
  # The one permitted `-d ... /.git` is inside mf_is_git_clone itself.
  _bad clone-predicate-has-one-definition "$_raw raw .git directory tests across lib/ -- a call site is carrying its own copy again"
elif [ "$_users" -lt 3 ]; then
  _bad clone-predicate-has-one-definition "only $_users call sites use mf_is_git_clone; prune, the counter and fetch_git should all be on it"
else
  _pass clone-predicate-has-one-definition
fi

# --- the help text ----------------------------------------------------------
# Both directories by name. "Remove all build artifacts" called them one thing,
# which is what made the cache a side effect rather than a decision.
_wired help-names-the-build-tree mediaforge.sh 'clean              Remove the build tree and unpacked sources'
_wired help-names-the-cache      mediaforge.sh '--all                 Also remove'

printf 'DONE: clean-modes\n'
exit "$_fail"
