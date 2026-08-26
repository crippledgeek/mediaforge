#!/bin/sh
# Remove the files a manifest lists, or collect the directories that emptied,
# doing every privileged step in this one process.
#
# _remove_manifest_entries (lib/install.sh) reads this file ONCE per process and
# runs its text as `$_priv sh -c "$_remove_helper" _ MODE TARGET_REAL LIST` —
# sudo for a system prefix, nothing for a user-owned one. This is the deletion
# counterpart of lib/install-one-file.sh, and it exists for the same two
# reasons that one does.
#
# CONTAINMENT. A manifest entry is composed onto the prefix lexically, and a
# lexical composition says nothing about where the path leads. Rejecting '..'
# and a leading '/' catches an entry that SPELLS an escape; it does nothing
# about `lib/foo.a` when <prefix>/lib is a symlink to /etc, because the escape
# is in the tree rather than in the text. That is the same gap #21 closed for
# the write path, and until this file the delete path did not have the fix:
# do_uninstall drove `sudo rm -f` on a lexically-checked path, and the prune
# added by #15 made the same primitive fire on every install, unattended, where
# uninstall at least asks first.
#
# So the check and the delete happen in ONE process, and the delete is issued
# RELATIVE to a directory this process has already entered — `cd` into the
# parent, confirm `pwd -P` is inside TARGET_REAL, then `rm -f -- ./name`. The
# kernel resolves './name' against the directory this process holds open as its
# CWD, so the intermediate components are never walked a second time and there
# is no window between the check and the delete in which one of them could be
# swapped. A leaf that is itself a symlink is unlinked, not followed — `rm`
# does not follow a symlink it is asked to remove.
#
# COST, and why this is not the trade #23 refused. The shape it replaced ran
# `$_priv rm -f` per entry: one setuid exec per file, ~250 on an install and
# 1527 on the uninstall that surfaced #15. Here the whole list costs ONE exec
# and every entry is still checked on its own, so the cheaper design is also
# the stricter one — there is nothing to trade.
#
# READ ONCE, not executed from disk per call, and a SEPARATE FILE rather than a
# string literal inside the caller: both for the reasons set out at length in
# lib/install-one-file.sh. As a file it is linted by tests/shellcheck.sh; a
# script spliced into an `sh -c` is not parsed by ShellCheck at all when the
# command word is "$_priv sh", so privileged code would go unchecked.
#
# It ends by printing REMOVED <count>. The caller requires that sentinel,
# because a script that is empty or truncated exits 0 under POSIX ("no
# commands" is success) and would otherwise be indistinguishable from a
# completed sweep that removed nothing — which is precisely the reading a
# damaged helper must not be able to buy.
#
# Refusals go to STDERR and do not stop the run: one unresolvable entry in a
# 1527-line manifest must not abandon the other 1526. stdout carries the
# sentinel and nothing else, so the caller can parse it.
#
# Exit codes, because the messages belong with die() in the caller:
#   0  completed — and REMOVED <n> printed on stdout; 0 without it is not success
#      (n counts files in 'files' mode and directories in 'dirs' mode: what this
#      invocation actually removed, so a caller can report it either way)
#   3  TARGET_REAL itself could not be resolved — nothing was attempted
#   4  wrong usage
#   7  the list could not be opened — nothing was attempted
#
# Every status is one the shell cannot produce on its own, so 1/2/126/127
# reaching the caller mean this file failed to run or to parse rather than
# anything it decided. 2 in particular is `sh`'s own syntax-error status.
set -u

[ "$#" -eq 3 ] || exit 4
_mode=$1
_target_real=$2
_list=$3
[ -n "$_target_real" ] && [ -n "$_list" ] || exit 4
case "$_mode" in
  files|dirs) ;;
  *) exit 4 ;;
esac

# TARGET_REAL is supposed to arrive already resolved — the caller has it. Re-cd
# anyway: an unresolvable or vanished target means every containment test below
# would compare against a path that is not there, and answering "not contained"
# for all of them would look identical to a clean run that found nothing.
_target_real=$(cd "$_target_real" 2>/dev/null && pwd -P) || exit 3
[ -n "$_target_real" ] || exit 3

# The list must be OPENABLE before either loop starts. `done < "$_list"` on a
# compound command does not abort a non-interactive shell when the redirection
# fails: execution falls through to the sentinel, which prints REMOVED 0, and
# the caller reads a clean "nothing left to remove" from a list it never read.
# That is the same "reported success having removed nothing" this file's header
# argues must not be purchasable — the root-owned 0600 manifest was one way in,
# and running as root closed only that one.
#
# Probed by actually opening it, in a subshell, rather than with `[ -r ]`: -r
# answers from the permission bits and can disagree with the open (ACLs, a
# filesystem mounted differently, a name that stops resolving). The subshell is
# what makes the failure observable — a bare `: < "$_list"` here would kill this
# shell outright with a status the caller reads as "the helper never ran".
( : < "$_list" ) 2>/dev/null || exit 7

_removed=0

# Enter $_target_real/$1 and confirm it really is inside $_target_real.
# Callers run this INSIDE the subshell that will do the removing, so the verdict
# and the act share a CWD.
_enter_contained() {
  cd "$_target_real/$1" 2>/dev/null || return 1
  case "$(pwd -P)/" in
    # The trailing '/' on the subject admits the prefix ROOT itself, which is
    # where a top-level entry like '.mediaforge-manifest' lands. The literal '/'
    # in the pattern is what excludes a SIBLING: '/opt/mf-evil/' does not match
    # '/opt/mf'/*. The expansion is quoted, so a prefix containing '*' or '?' is
    # matched literally and cannot widen the pattern.
    "$_target_real"/*) return 0 ;;
  esac
  return 1
}

# Reject entries that SPELL a traversal. This is redundant with the containment
# check above, not a necessary condition alongside it: traced against every
# shape the tests feed it, `_enter_contained` refuses each one on its own — a
# '../' entry lands in the real parent and fails the prefix match, and an
# absolute entry names a directory under the prefix that does not exist, so the
# `cd` fails. Mutation testing agrees: disabling this guard alone changes no
# assertion, while loosening containment alone does.
#
# Kept as a cheap fast path and as defense in depth, applied to both modes from
# one place so the two can never disagree — but it is NOT what makes the
# deletion safe, and a reader must not come away believing it is. Containment
# is. See the header, and tests/install-manifest-reconcile.sh's symlinked-class
# -directory case, which is the assertion that actually pins it.
_traverses() {
  case "$1" in
    /*|*/../*|../*|..) return 0 ;;
  esac
  return 1
}

if [ "$_mode" = files ]; then
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    if _traverses "$_rel"; then
      printf 'mediaforge: suspicious manifest entry skipped: %s\n' "$_rel" >&2
      continue
    fi

    # An entry with no '/' lives at the prefix root; ${_rel%/*} would then be
    # the whole entry rather than its directory, which is the same shape
    # lib/install-one-file.sh rejects a trailing slash to avoid.
    case "$_rel" in
      */*) _dir=${_rel%/*}; _base=${_rel##*/} ;;
      *)   _dir=.;          _base=$_rel ;;
    esac
    # A trailing slash names a directory, and this removes files.
    [ -n "$_base" ] || continue

    ( _enter_contained "$_dir" || exit 6
      [ -f "./$_base" ] || exit 1
      rm -f -- "./$_base" || exit 5
    )
    case $? in
      0) _removed=$((_removed + 1)) ;;
      6) printf 'mediaforge: refusing to delete %s — it resolves outside %s\n' \
           "$_rel" "$_target_real" >&2 ;;
      5) printf 'mediaforge: failed to delete %s\n' "$_rel" >&2 ;;
      *) : ;;   # not present: the ordinary case for an already-removed entry
    esac
  done < "$_list"
else
  # Climb from each entry's own directory up toward the target, removing what
  # `rmdir` finds empty. The refusal to remove a non-empty directory is the
  # kernel's, which is what keeps a shared prefix's other packages safe without
  # this needing to know anything about them.
  #
  # Each rmdir is issued from inside the PARENT, for the same reason the unlink
  # above is: 'rmdir ./name' cannot be redirected by swapping a component of a
  # path it never walks. rmdir does not follow a symlink at the final component
  # either, so a symlinked directory name fails rather than removing its target.
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    _traverses "$_rel" && continue
    case "$_rel" in
      */*) _dir=${_rel%/*} ;;
      # No directory component: nothing between this entry and the prefix root,
      # and the root itself is not ours to remove here — do_uninstall does that
      # last, deliberately, and only for a prefix that ended up empty.
      *) continue ;;
    esac

    while [ -n "$_dir" ] && [ "$_dir" != "." ]; do
      case "$_dir" in
        */*) _parent=${_dir%/*}; _leaf=${_dir##*/} ;;
        *)   _parent=.;          _leaf=$_dir ;;
      esac
      ( _enter_contained "$_parent" || exit 6
        rmdir -- "./$_leaf" 2>/dev/null || exit 1
      )
      case $? in
        0) _removed=$((_removed + 1)) ;;
        # Reported, like the file-mode refusal is. Both fail closed, so this is
        # not a safety gap — but an operator whose directory cleanup stops
        # because a component is a symlink gets no clue why from a silent break,
        # and "the prefix was left behind" with no reason given is the exact
        # shape of the #15 report this all came from.
        6) printf 'mediaforge: refusing to remove directory %s — it resolves outside %s\n' \
             "$_dir" "$_target_real" >&2
           break ;;
        # Not empty, or already gone. The ordinary outcome, and the signal to
        # stop climbing: every level above this one holds it.
        *) break ;;
      esac
      _dir=$_parent
    done
  done < "$_list"
fi

# The sentinel, last: reaching EOF is not evidence the work happened, but
# printing this after the loop completed is.
printf 'REMOVED %s\n' "$_removed"
