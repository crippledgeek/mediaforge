#!/bin/sh
# Every privileged deletion mediaforge performs, in one process, with one
# containment rule.
#
# _remove_manifest_entries (lib/install.sh) reads this file ONCE per process and
# runs its text as `$_priv sh -c "$_remove_helper" _ MODE TARGET_REAL LIST` —
# sudo for a system prefix, nothing for a user-owned one. This is the deletion
# counterpart of lib/install-one-file.sh, and it exists for the same two reasons
# that one does.
#
# CONTAINMENT. A path composed onto the prefix lexically says nothing about
# where it leads. Rejecting '..' and a leading '/' catches a name that SPELLS an
# escape; it does nothing about `lib/foo.a` when <prefix>/lib is a symlink to
# /etc, because the escape is in the tree rather than in the text. That is the
# gap #21 closed for the write path, and until this file the delete path did not
# have the fix: do_uninstall drove `sudo rm -f` on a lexically-checked path, and
# the prune added by #15 made the same primitive fire on every install,
# unattended, where uninstall at least asks first.
#
# So the check and the delete happen in ONE process, and the delete is issued
# RELATIVE to a directory this process has already entered — `cd` into the
# parent, confirm `pwd -P` is inside TARGET_REAL, then `rm -f -- ./name`. The
# kernel resolves './name' against the directory this process holds open as its
# CWD, so the intermediate components are never walked a second time and there
# is no window in which one of them could be swapped. A leaf that is itself a
# symlink is unlinked, not followed — `rm` does not follow a symlink it is asked
# to remove, and `rmdir` refuses one outright.
#
# FOUR MODES, ONE RULE. Every mode routes through _remove_entry, so the rule
# above is written once and cannot come to exist in only some of them.
#
# The rule's scope is every delete of something INSIDE the prefix, and every one
# of them routes through here — including the manifest, which was argued for a
# while as a safe exception because it is a direct child of the prefix. That
# argument was sound only about the RESOLVED boundary, and only if the boundary
# were re-checked at the moment of the delete rather than inherited from a
# string resolved earlier in the run. Two conditions are more than a comment
# should be asked to defend when this file already guarantees both.
#
# ONE privileged delete remains outside, and it is genuinely a different thing:
# `rmdir "$_target_real"` removes the PREFIX — the boundary itself, not
# something within it — and `rmdir` does not follow a symlink at the final
# component. It is commented where it sits. Said here so this header claims what
# it does and not more:
#
#   files      delete each path the LIST names          (the manifest)
#   dirs       climb from each LIST path toward the     (the manifest)
#              prefix, removing what is now empty
#   links      delete the DANGLING symlinks under       (subtree roots)
#              each LIST root
#   emptydirs  remove every empty directory under       (subtree roots)
#              each LIST root, deepest first
#
# The last two used to be `find | while ...; $_priv rm -f "$_link"` loops in
# do_uninstall: a `[ ! -e ]` test followed by a delete on the same composed
# string, which is a check-then-act gap on a path nothing had entered. They were
# briefly kept and documented as a narrower, accepted risk; that was the wrong
# call, and being the only two deletes outside the rule is exactly how a rule
# stops being one. Doing the enumeration HERE also fixes a second defect they
# carried: `find` ran unprivileged in the caller, so on a root-owned prefix it
# could not read the tree it was enumerating.
#
# COST, and why this is not the trade #23 refused. The shape it replaced ran
# `$_priv rm -f` per entry: one setuid exec per file, ~250 on an install and
# 1527 on the uninstall that surfaced #15. Here a whole list costs ONE exec and
# every entry is still checked on its own, so the cheaper design is also the
# stricter one — there is nothing to trade.
#
# READ ONCE, not executed from disk per call, and a SEPARATE FILE rather than a
# string literal inside the caller: both for the reasons set out at length in
# lib/install-one-file.sh. As a file it is linted by tests/shellcheck.sh; a
# script spliced into an `sh -c` is not parsed by ShellCheck at all when the
# command word is "$_priv sh", so privileged code would go unchecked.
#
# It ends by printing REMOVED <count>. The caller requires that sentinel,
# because a script that is empty or truncated exits 0 under POSIX ("no commands"
# is success) and would otherwise be indistinguishable from a completed sweep
# that removed nothing — precisely the reading a damaged helper must not buy.
#
# Refusals go to STDERR and do not stop the run: one unresolvable entry in a
# 1527-line manifest must not abandon the other 1526. stdout carries the
# sentinel and nothing else, so the caller can parse it.
#
# A PARTIAL SWEEP goes the same way (GH-80). The two subtree-walking modes used
# to discard find's status into a pipeline's, so a subtree they could not descend
# was left unswept and the run still reported a clean removal. The status is
# carried now, and the answer is a line on stderr rather than a failure: leftovers
# are visible on disk and removable by hand, which is not true of the manifest
# under-recording the same defect caused on the staging side.
#
# Exit codes, because the messages belong with die() in the caller:
#   0  completed — and REMOVED <n> printed on stdout; 0 without it is not success
#      (n is what THIS invocation removed: files, directories, or links)
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
  files|dirs|links|emptydirs) ;;
  *) exit 4 ;;
esac

# TARGET_REAL is supposed to arrive already resolved — the caller has it. Re-cd
# anyway: an unresolvable or vanished target means every containment test below
# would compare against a path that is not there, and answering "not contained"
# for all of them would look identical to a clean run that found nothing.
_target_real=$(cd "$_target_real" 2>/dev/null && pwd -P) || exit 3
[ -n "$_target_real" ] || exit 3

# Read ONCE, here, and iterate the text below. Not `[ -r ]`, which answers from
# the permission bits and can disagree with the open (ACLs, a filesystem mounted
# differently, a name that stops resolving) — this is a real open, and its
# failure is the refusal.
#
# ONE open, deliberately. A probe followed by `done < "$_list"` opens the path
# twice, and a list that becomes unopenable between them puts the loop straight
# back into the silent fall-through this exists to prevent — narrowing a
# deterministic bug into a race rather than closing it. There is no window here:
# what the loops iterate is the text this line already read.
#
# `cat` in a command substitution rather than a redirection, because the obvious
# spellings are fatal before their own error handling runs. Measured 2026-08-26
# against a mode-000 list, `|| exit 7` attached to each:
#
#   form                              bash-as-sh   dash
#   exec 3< "$_list"                           1      2
#   : < "$_list"                               1      2
#   _list_text=$(cat "$_list")                 7      7
#
# A redirection failure on a special builtin kills a non-interactive shell
# before the `||` is reached, and the status it dies with is shell-dependent —
# both values land on the WRONG arm in the caller, 1 saying the helper never ran
# and 2 saying its text is truncated, sending an operator to audit a file that
# is perfectly intact when the real problem is a manifest they cannot read.
# `cat` is an ordinary command owning its own redirection, so it simply fails.
#
# stderr is dropped, so EACCES and ENOENT arrive as one status; the caller's
# message names the path and who needs to read it, which is what an operator
# acts on either way.
_list_text=$(cat "$_list" 2>/dev/null) || exit 7

_removed=0
# Set when any enumeration below could not read part of the tree it was sweeping.
# A COUNT would be the obvious thing and is the wrong thing: the emptydirs mode
# runs its walk to a fixpoint, so the same unreadable subtree is met once per
# cycle and a count would report the number of attempts rather than the number of
# places. A flag says the one thing an operator can act on -- the sweep was
# partial -- and says it once.
_partial_sweep=0

# Enter $_target_real/$1 and confirm it really is inside $_target_real. Callers
# run this INSIDE the subshell that will do the removing, so the verdict and the
# act share a CWD.
#
# Three outcomes, not two: 0 entered and contained, 1 could not enter at all,
# 2 entered but it resolves outside. The distinction matters because they mean
# opposite things to an operator — a directory that is simply GONE is the
# ordinary case for an entry someone already deleted by hand, while one that
# resolves outside is a refusal worth printing. Collapsing them made a missing
# parent report "refusing to remove X - it resolves outside": a false alarm
# about an attack, for a tree that is merely tidy.
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
  return 2
}

# Reject paths that SPELL a traversal. This is redundant with the containment
# check above, not a necessary condition alongside it: traced against every
# shape the tests feed it, `_enter_contained` refuses each one on its own — a
# '../' entry lands in the real parent and fails the prefix match, and an
# absolute entry names a directory under the prefix that does not exist, so the
# `cd` fails. Mutation testing agrees: disabling this guard alone changes no
# assertion, while loosening containment alone does.
#
# Kept as a cheap fast path and as defense in depth, applied to every mode from
# one place so they can never disagree — but it is NOT what makes the deletion
# safe, and a reader must not come away believing it is. Containment is. See the
# header, and tests/install-manifest-reconcile.sh's symlinked-class-directory
# case, which is the assertion that actually pins it.
_traverses() {
  case "$1" in
    /*|*/../*|../*|..) return 0 ;;
  esac
  return 1
}

# THE one deletion primitive. $1 is a prefix-relative path, $2 its kind
# (file|link|dir). Enters the parent, re-checks containment from inside it, and
# acts on the leaf by name — never on a composed path.
#
# Returns 0 when it removed something, 6 when containment refused, 5 when the
# removal itself failed, and 1 when there was nothing to remove (the ordinary
# outcome for an entry a user already deleted by hand).
_remove_entry() {
  case "$1" in
    */*) _re_dir=${1%/*}; _re_base=${1##*/} ;;
    # No directory component: the leaf sits at the prefix root.
    *)   _re_dir=.;       _re_base=$1 ;;
  esac
  # A trailing slash names a directory through a file-shaped path.
  [ -n "$_re_base" ] || return 1
  # '.' and '..' as a leaf are never ours to remove: they are the entered
  # directory and its parent, not entries within it.
  case "$_re_base" in .|..) return 1 ;; esac

  ( _enter_contained "$_re_dir"
    case $? in
      0) ;;
      # Parent gone: the entry is already removed. Silent, and not a refusal.
      1) exit 1 ;;
      *) exit 6 ;;
    esac
    case "$2" in
      file) [ -f "./$_re_base" ] || exit 1
            rm -f -- "./$_re_base" || exit 5 ;;
      # DANGLING only: -L says it is a symlink, ! -e says its target is not
      # there. A live symlink is someone's working shim and stays.
      link) { [ -L "./$_re_base" ] && [ ! -e "./$_re_base" ]; } || exit 1
            rm -f -- "./$_re_base" || exit 5 ;;
      # rmdir refuses a non-empty directory, which is what keeps a shared
      # prefix's other packages safe without this knowing anything about them.
      # It refuses a symlink too, rather than following it.
      dir)  rmdir -- "./$_re_base" 2>/dev/null || exit 1 ;;
      *)    exit 1 ;;
    esac
  )
}

# Report a containment refusal in the same words for every mode.
_refused() {
  printf 'mediaforge: refusing to remove %s — it resolves outside %s\n' \
    "$1" "$_target_real" >&2
}

# Prefix-relative paths under $1 matching the find predicate in $2..., emitted
# one per line. Enters the root first, so the enumeration itself is contained
# and — because this process holds the privilege — can read a root-owned tree
# the caller's own `find` could not.
#
# `find` is NOT given -L or -H, so it does not follow a symlink it meets: a
# symlinked class directory is reported as a link rather than descended into,
# which is what stops an enumeration from wandering out of the prefix before
# _remove_entry ever sees a path.
#
# NEWLINES IN FILENAMES are the one thing this cannot parse, and the caveat is
# larger here than for the manifest modes. `find | sed` into a line-based `read`
# splits a name containing a newline across two lines. The manifest is written
# by mediaforge; these two modes enumerate the LIVE tree under subtrees the
# comments in do_uninstall acknowledge other packages and the user may populate,
# so the input is no longer only ours. The consequence is bounded and does not
# reach outside the prefix: both halves of a split name still go through
# _remove_entry, which enters, re-checks containment, and applies the kind test,
# so the worst case is failing to sweep the intended entry, or sweeping a
# different ALREADY-dangling link or ALREADY-empty directory under the same
# contained root. Nothing live, nothing non-empty, nothing outside.
#
# Not fixed, because there is no portable fix: `find -print0` with `read -d ''`
# is a GNU/bash pair and this is POSIX sh targeting dash as well. Recorded
# rather than left for the next reader to rediscover.
_enumerate() {
  _en_root=$1
  shift
  ( _enter_contained "$_en_root"
    case $? in
      0) ;;
      # Root absent — this prefix simply has no such subtree. Nothing to sweep
      # and nothing worth saying.
      1) exit 0 ;;
      # Present but pointing out of the prefix. Every other refusal in this file
      # is reported; an enumeration that silently finds nothing would leave an
      # operator with a surviving prefix and no reason for it.
      #
      # Like _traverses, this is defense in depth rather than the thing that
      # makes the sweep safe, and it is honestly NOT pinned: mutating it away
      # changes no assertion, because _remove_entry re-checks containment for
      # every path the enumeration produces and refuses each one. What it buys
      # is not walking a tree outside the prefix at all, and saying so.
      *) _refused "$_en_root"; exit 0 ;;
    esac
    # The walk's status is CARRIED, not discarded into sed's (GH-80). As
    # `find | sed` the status belonged to sed and the `2>/dev/null` removed the
    # only other evidence, so a subtree find could not descend simply was not
    # swept: dangling links and empty directories left behind, and an uninstall
    # that called itself complete. Same defect as lib/stage.sh's manifest walk,
    # and NOT the same consequence -- this under-REMOVES where that
    # under-RECORDS. Leftovers are visible on disk and removable by hand; a stamp
    # that under-records is permanent and nothing re-derives it. So this one
    # reports and carries on, in the direction the header already commits to:
    # one unresolvable entry must not abandon the rest of the sweep.
    #
    # What it found is still emitted before the status is returned. A partial
    # list is worth sweeping -- every path in it is one the caller then puts
    # through _remove_entry, which re-checks containment for each -- and dropping
    # it would turn "read part of the tree" into "removed none of it".
    #
    # NOT folded onto lib/stage.sh's mf_stage_walk_files, which is a walk for
    # files and symlinks and nothing else: the predicate here is the caller's
    # whole question (`-type l`, or `-depth -type d -empty`), so sharing the
    # helper would mean parameterising away the one thing that makes it one
    # mechanism. This file is also read and run as its own privileged process and
    # sources nothing.
    _en_st=0
    _en_out=$(find . "$@" 2>/dev/null) || _en_st=8
    [ -z "$_en_out" ] || printf '%s\n' "$_en_out" | sed 's|^\./||'
    exit "$_en_st" )
}

case "$_mode" in
files)
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    if _traverses "$_rel"; then
      printf 'mediaforge: suspicious manifest entry skipped: %s\n' "$_rel" >&2
      continue
    fi
    _remove_entry "$_rel" file
    case $? in
      0) _removed=$((_removed + 1)) ;;
      6) _refused "$_rel" ;;
      5) printf 'mediaforge: failed to delete %s\n' "$_rel" >&2 ;;
      *) : ;;
    esac
  # A here-document, NOT a pipe: a pipeline puts the loop body in a subshell,
  # where every _removed increment is discarded when it exits and the sentinel
  # would report 0 for a sweep that removed everything. The here-doc body is a
  # parameter expansion, and an expansion's RESULT is not rescanned — a manifest
  # line containing $(...) or a backtick arrives as those literal characters.
  # Verified 2026-08-26 under both sh and dash.
  done <<EOF
$_list_text
EOF
  ;;

dirs)
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    _traverses "$_rel" && continue
    case "$_rel" in
      */*) _dir=${_rel%/*} ;;
      # Nothing between this entry and the prefix root, and the root itself is
      # not ours to remove here — do_uninstall does that last, deliberately, and
      # only for a prefix that ended up empty.
      *) continue ;;
    esac
    # Climb toward the prefix, stopping at the first level that will not go:
    # every level above a directory that is still populated holds it too.
    while [ -n "$_dir" ] && [ "$_dir" != "." ]; do
      _remove_entry "$_dir" dir
      case $? in
        0) _removed=$((_removed + 1)) ;;
        6) _refused "$_dir"; break ;;
        *) break ;;
      esac
      case "$_dir" in
        */*) _dir=${_dir%/*} ;;
        *)   _dir=. ;;
      esac
    done
  done <<EOF
$_list_text
EOF
  ;;

links)
  while IFS= read -r _root; do
    [ -z "$_root" ] && continue
    _traverses "$_root" && continue
    _found=$(_enumerate "$_root" -type l) || _partial_sweep=1
    [ -n "$_found" ] || continue
    while IFS= read -r _rel; do
      [ -z "$_rel" ] && continue
      [ "$_rel" = "." ] && continue
      _remove_entry "$_root/$_rel" link
      case $? in
        0) _removed=$((_removed + 1)) ;;
        6) _refused "$_root/$_rel" ;;
        *) : ;;
      esac
    done <<INNER
$_found
INNER
  done <<EOF
$_list_text
EOF
  ;;

emptydirs)
  # Repeated to a fixpoint rather than trusting one `find -depth` pass. find
  # decides -empty when it VISITS a directory, and the removals happen after the
  # enumeration is collected — so a parent that becomes empty only once its last
  # child is removed is not in that first listing. Each cycle removes at least
  # one directory or ends the loop, and directories are finite, so this
  # terminates; it is also strictly more thorough than the single pass it
  # replaces, which left such parents behind.
  while :; do
    _any=0
    while IFS= read -r _root; do
      [ -z "$_root" ] && continue
      _traverses "$_root" && continue
      _found=$(_enumerate "$_root" -depth -type d -empty) || _partial_sweep=1
      [ -n "$_found" ] || continue
      while IFS= read -r _rel; do
        [ -z "$_rel" ] && continue
        # find prints '.' for the root itself when it is empty; the root is a
        # real candidate (an emptied lib/ should go), but it is named by
        # $_root, not by "$_root/.".
        if [ "$_rel" = "." ]; then
          _cand=$_root
        else
          _cand=$_root/$_rel
        fi
        _remove_entry "$_cand" dir
        case $? in
          0) _removed=$((_removed + 1)); _any=1 ;;
          6) _refused "$_cand" ;;
          *) : ;;
        esac
      done <<INNER
$_found
INNER
    done <<EOF
$_list_text
EOF
    [ "$_any" = 1 ] || break
  done
  ;;
esac

# BEFORE the sentinel, and on stderr like every other refusal: the count on
# stdout is what the caller parses, and it stays the honest number of things this
# invocation removed. What it cannot say is that the sweep looked everywhere, and
# an uninstall reporting "Removed 1527 files" over a subtree it never read is the
# same confident-wrong answer GH-80 is about, one direction over.
#
# Not an exit status, deliberately. The caller's contract is 0-with-REMOVED for a
# completed run and a distinct code for each way the helper never ran; a partial
# sweep is neither, and spending a new code on it would make every caller decide
# what to do about leftovers that are visible on disk and removable by hand.
[ "$_partial_sweep" = 0 ] || printf 'mediaforge: part of %s could not be read; removed what was visible, and there may be more left behind\n' "$_target_real" >&2

# The sentinel, last: reaching EOF is not evidence the work happened, but
# printing this after the loop completed is.
printf 'REMOVED %s\n' "$_removed"
