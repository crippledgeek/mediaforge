#!/bin/sh
# Install ONE file, doing every privileged step in this one process.
#
# _install_file (lib/install.sh) reads this file ONCE per process and runs its
# text as `$_priv sh -c "$_install_helper" _ SRC DEST PREFIX_REAL` — sudo for a
# system prefix, nothing for a user-owned one. It resolves the destination,
# refuses it if it leads outside PREFIX_REAL, creates the missing directories,
# unlinks whatever sits at the leaf, and copies.
#
# READ ONCE, not executed from disk per file. Running it as a path under sudo
# would re-read this file ~250 times per install, each read a chance to execute
# something the checkout did not contain when the install started. Read once,
# unprivileged, before the first copy, that window is a single read.
#
# WHY ONE PROCESS. Done as separate sudo calls this costs five setuid execs per
# file — a `test -d` ancestor walk, an `sh -c` resolve, then mkdir, rm and cp —
# and a real FFmpeg tree installs ~250 files (#23). That price is what made
# re-checking every file look expensive enough to trade away for a per-directory
# cache, which let later files ride on a verdict earned by an earlier one. Here
# each file is checked on its own AND costs one exec, so there is no trade: the
# gap between the check and the write is microseconds of straight-line shell in
# a single process, rather than a window spanning other files' copies.
#
# It is NOT atomic, and POSIX offers a shell no way to make it so — no
# open-and-hold, no O_NOFOLLOW for cp. What remains is a race that must be won
# between two adjacent statements by someone who already has write access under
# a prefix only root should be writing to.
#
# A SEPARATE FILE rather than a string literal inside _install_file: a script
# written inline there cannot be linted — ShellCheck parses an `sh -c` script
# only when the command word and the script are both literal, and the command
# word is "$_priv sh". Privileged code would go unchecked. As a file it is
# linted like every other by tests/shellcheck.sh, and it is read from the same
# tree lib/install.sh is sourced from, so it is exactly as trusted as its caller
# and no more.
#
# It ends by printing INSTALLED. The caller requires that sentinel, because a
# script that is empty or truncated exits 0 under POSIX ("no commands" is
# success) and would otherwise be indistinguishable from a completed install:
# no containment check, no copy, and a manifest entry claiming both.
#
# Exit codes, because the messages belong with die() in the caller:
#   0  installed — and INSTALLED printed on stdout; 0 without it is not success
#   3  destination could not be resolved at all
#   4  wrong usage
#   5  the copy failed
#   6  destination resolves outside the prefix — the resolved path on stdout
#
# 6, not 2, for the containment refusal: 2 is what `sh` itself returns for a
# SYNTAX ERROR, so a helper truncated in the middle of a `case` or `while` would
# arrive at the caller wearing the one status that means "a symlink is taking
# your privileged write out of the prefix" — sending the operator after an
# attack that is not happening, for a file that is merely damaged. Every status
# this script returns is therefore one the shell cannot produce on its own.
set -u

[ "$#" -eq 3 ] || exit 4
_src=$1
_dest=$2
_prefix_real=$3
[ -n "$_dest" ] && [ -n "$_prefix_real" ] || exit 4

# A trailing slash is REJECTED, not normalised. ${_dest%/*} is not dirname:
# for "<prefix>/deep/" dirname says "<prefix>" and ${_dest%/*} says
# "<prefix>/deep", so mkdir would create the destination itself as a directory,
# rm -f would fail on it, cp would land the file INSIDE it under the source's
# basename, and this would still exit 0 — with the caller manifesting a path
# that holds nothing. Normalising instead would install to a path the caller did
# not name. No caller passes this shape; refusing it is how it stays that way,
# and it is also what keeps this walk from ever disagreeing with the dirname one
# in _nearest_existing (lib/install.sh), which the two cannot share: this text
# runs in a bare `sh -c` as root with no functions in scope, and sourcing a
# library as root to import one would be the worse trade.
case "$_dest" in
  */) exit 4 ;;
esac

_dir=${_dest%/*}
[ -n "$_dir" ] || _dir=/

# Nearest EXISTING ancestor: cd/pwd -P answer only for paths that exist, and an
# install destination mostly does not yet. Plain [ -d ], not a privileged probe
# — this process already holds the privilege, which is the whole point.
_probe=$_dir
while [ ! -d "$_probe" ]; do
  _next=${_probe%/*}
  [ -n "$_next" ] || _next=/
  # A path that no longer shortens has nowhere left to walk; without this the
  # loop spins forever on a relative path, which the caller does not pass but
  # this file should not depend on.
  [ "$_next" = "$_probe" ] && break
  _probe=$_next
done

_real=$(cd "$_probe" 2>/dev/null && pwd -P)
[ -n "$_real" ] || exit 3

# The trailing '/' on the subject admits the prefix ROOT itself: '/opt/mf' does
# not match '/opt/mf'/*, but '/opt/mf/' does, since '*' matches empty. That is
# the common FIRST-install case — the nearest existing ancestor of <prefix>/bin
# is <prefix> — so dropping the slash would refuse a legitimate destination. It
# is NOT what excludes a sibling; the literal '/' in the pattern does that alone
# ('/opt/mf-evil/' does not match). The expansion is QUOTED, so a prefix holding
# '*' or '?' is matched literally and cannot widen the pattern.
case "$_real/" in
  "$_prefix_real"/*) : ;;
  *) printf '%s\n' "$_real"; exit 6 ;;
esac

mkdir -p "$_dir" 2>/dev/null

# Resolved AGAIN, now that the directory itself exists. The answer above was
# about an ANCESTOR and says nothing about the components mkdir has just walked
# through — and mkdir -p follows a symlink component it meets on the way. This
# is the check no pre-mkdir resolution can make, and it is affordable only
# because here it costs no exec.
_real2=$(cd "$_dir" 2>/dev/null && pwd -P)
[ -n "$_real2" ] || exit 3
case "$_real2/" in
  "$_prefix_real"/*) : ;;
  *) printf '%s\n' "$_real2"; exit 6 ;;
esac

# Unlink first: cp FOLLOWS a symlink at the destination and overwrites what it
# points at, leaving the link itself in place. A symlink pre-planted at the leaf
# — planted while the prefix was writable, no race required — would otherwise
# redirect this privileged copy into a file chosen by whoever planted it. rm -f
# removes the LINK without following it, and POSIX cp has no portable
# --no-dereference-on-write.
rm -f -- "$_dest"
cp -- "$_src" "$_dest" || exit 5

# The sentinel, last: reaching EOF is not evidence the work happened, but
# printing this after the copy returned 0 is.
printf 'INSTALLED\n' 
