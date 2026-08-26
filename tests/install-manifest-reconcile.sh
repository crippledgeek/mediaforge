#!/bin/sh
# Install-manifest reconciliation — regression tests for crippledgeek/mediaforge#15.
#
# do_install used to create an EMPTY manifest accumulator per run, append only
# what that run copied, and then overwrite the previous manifest wholesale. It
# never removed anything. So a file shipped by an older build and dropped by a
# newer one stayed on disk AND vanished from the record — and do_uninstall,
# which iterates the manifest and nothing else, could not see it again. The
# instance that surfaced it was V-Nova's split lcevc archives, orphaned by
# 829b927 merging them into one; eight .a files survived an uninstall that
# reported success, and the "isolated prefix removes itself" behaviour silently
# degraded to "prefix left behind".
#
# Most assertions here are COMPOUND, deliberately. tests/oracle-baseline.sh
# requires that no assertion passes on the merge base, and each half that proves
# the prune is conservative — a foreign file survives, a traversing entry is
# refused, a still-shipped file is kept — is true on the base as well, where
# nothing is pruned at all. Pairing each with a removal the base fails to
# perform is what keeps the safety half asserted without buying a free pass.
#
# The two directory-guard cases are the exception and need no pairing: they are
# driven through UNINSTALL with a tampered manifest, where the base really does
# act and really does get it wrong.
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
_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

# One temp root for the whole file, removed on exit however we leave. Each case
# takes a fresh subdirectory of it, so a `exit 1` on a later mktemp cannot strand
# the dirs the earlier cases made.
_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT INT TERM

# $1 names a case; sets _s (staging prefix), _d (install prefix) and _out_dir as
# siblings, so a manifest entry of "../<name>" reaches a known path outside the
# install prefix without depending on how mktemp names things.
_case() {
  _s="$_tmp/$1/stage"
  _d="$_tmp/$1/dest"
  _out_dir="$_tmp/$1"
  mkdir -p "$_s" "$_d" || exit 1
}

# Driven in a separate `sh` rather than a ( ) subshell, matching
# tests/install-containment.sh: do_install reads PREFIX/AUTOINSTALL from the
# environment, and shadowing this script's own PREFIX inside a subshell would
# both confuse the reader and leak install.sh's functions into the assertions.
#
# Both merge stderr internally, so call sites need no redirection of their own —
# the output is captured and several assertions read it.
_run_install() {
  PREFIX="$1" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$2" 2>&1
}

_run_uninstall() {
  PREFIX="$1" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_uninstall "$1"
  ' _ "$2" 2>&1
}

# A staging prefix holding one file of each class this file exercises, plus the
# two that a later "version" drops: a static archive beside one it keeps, and a
# header in a subdirectory of its own so the directory sweep has something to
# collect.
_make_stage() {
  mkdir -p "$1/bin" "$1/lib" "$1/include/drop" "$1/.logs"
  printf 'FFMPEG-BINARY\n' > "$1/bin/ffmpeg"
  printf 'KEPT-LIB\n'       > "$1/lib/libmediaforge-keep.a"
  printf 'DROPPED-LIB\n'    > "$1/lib/libmediaforge-drop.a"
  printf 'HEADER\n'         > "$1/include/mediaforge-probe.h"
  printf 'DROPPED-HEADER\n' > "$1/include/drop/mediaforge-drop.h"
}

# The newer "version": the same stage with the two files the recipe no longer
# ships. Mirrors recipes/other/lcevc.sh dropping the split archives.
_drop_from_stage() {
  rm -f "$1/lib/libmediaforge-drop.a" "$1/include/drop/mediaforge-drop.h"
  rmdir "$1/include/drop" 2>/dev/null || :
}

# Every regular file under the prefix, manifest excluded, prefix-relative and
# sorted — the set the manifest is supposed to describe exactly.
_disk_set() {
  ( cd "$1" 2>/dev/null || exit 0
    find . -type f ! -name .mediaforge-manifest | sed 's|^\./||' | LC_ALL=C sort )
}

# ─── an install-over-install removes what the new build no longer ships ─────
# Compound with the kept archive: "libmediaforge-keep.a is still there" is true
# on the base too, where nothing is removed at all.
_case drop
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_drop_from_stage "$_s"
_prune_out=$(_run_install "$_s" "$_d")
if [ ! -e "$_d/lib/libmediaforge-drop.a" ] && [ -f "$_d/lib/libmediaforge-keep.a" ]; then
  _pass "a dropped static archive is pruned on reinstall, the kept one survives"
else
  _bad "a dropped static archive is pruned on reinstall, the kept one survives"
fi

# The manifest is the record uninstall acts on, so what it says has to match
# what is on disk EXACTLY — not merely omit the pruned entry, which the base
# also does (it overwrites the manifest wholesale, which is how the file went
# missing from the record while staying on disk). Comparing both directions is
# what makes this an oracle for the finalize as well as for the prune: a prune
# that removed too much, or a manifest that forgot a file it installed, both
# show up here and in nothing else.
_manifest_set=$(LC_ALL=C sort "$_d/.mediaforge-manifest" 2>/dev/null)
if [ -n "$_manifest_set" ] && [ "$_manifest_set" = "$(_disk_set "$_d")" ]; then
  _pass "after the prune the manifest and the installed tree describe the same set"
else
  _bad "after the prune the manifest and the installed tree describe the same set"
fi

# The count is reported, and it is the count of files actually removed. Silence
# would leave an operator with no way to know a privileged deletion happened.
if printf '%s\n' "$_prune_out" | grep -q 'pruned 2 file(s)'; then
  _pass "the prune reports how many files it removed"
else
  _bad "the prune reports how many files it removed"
fi

# A directory the prune empties is collected, like the bottom-up sweep
# do_uninstall already runs. Paired with the surviving sibling header.
if [ ! -d "$_d/include/drop" ] && [ -f "$_d/include/mediaforge-probe.h" ]; then
  _pass "a directory emptied by the prune is removed, its sibling header is not"
else
  _bad "a directory emptied by the prune is removed, its sibling header is not"
fi

# ─── the prune touches nothing mediaforge did not install ───────────────────
# The shared-prefix case (~/.local, /usr/local): a file the manifest never
# listed is not ours to remove, however it got there.
_case foreign
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
printf 'NOT-OURS\n' > "$_d/lib/libsomeone-else.a"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
if [ -f "$_d/lib/libsomeone-else.a" ] && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass "a file mediaforge never installed survives the prune"
else
  _bad "a file mediaforge never installed survives the prune"
fi

# ─── a traversing entry in the OLD manifest is refused ──────────────────────
# The prune reads a file that lives inside the install prefix and drives `rm -f`
# from it, under sudo for a system prefix. That is the same trust boundary
# do_uninstall guards at its own read, so the same refusal has to apply here —
# on the copy of the manifest that was on disk BEFORE this run, which is the one
# an earlier compromise could have edited.
#
# All three spellings the guard claims to cover, not just the leading one: a
# relative climb, a climb from the middle of an otherwise innocent path, and an
# absolute path that ignores the prefix altogether.
_case traverse
_make_stage "$_s"
mkdir -p "$_out_dir/escape"
printf 'OUTSIDE\n' > "$_out_dir/escape/probe"
printf 'ABSOLUTE\n' > "$_out_dir/absolute-probe"
_run_install "$_s" "$_d" >/dev/null
{ printf '../escape/probe\n'
  printf 'lib/../../escape/probe\n'
  printf '%s\n' "$_out_dir/absolute-probe"
} >> "$_d/.mediaforge-manifest"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
if [ -f "$_out_dir/escape/probe" ] \
   && [ -f "$_out_dir/absolute-probe" ] \
   && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass "relative, mid-path and absolute manifest entries are all refused by the prune"
else
  _bad "relative, mid-path and absolute manifest entries are all refused by the prune"
fi

# ─── the directory sweep refuses a traversing entry too ─────────────────────
# Driven through uninstall, because that is where the base reaches the sweep at
# all. The base's climb had no traversal guard: dirname("../victim/x") is
# "../victim", and the climb stops only when it reaches the target, so `rmdir`
# was invoked on a directory outside the prefix and removed it when it happened
# to be empty. An EMPTY directory is therefore the whole test — a non-empty one
# is saved by rmdir's own refusal and proves nothing about the guard.
_case sweep
_make_stage "$_s"
mkdir -p "$_out_dir/victim"
_run_install "$_s" "$_d" >/dev/null
printf '../victim/ghost\n' >> "$_d/.mediaforge-manifest"
_run_uninstall "$_s" "$_d" >/dev/null
if [ -d "$_out_dir/victim" ]; then
  _pass "an empty directory outside the prefix survives a traversing manifest entry"
else
  _bad "an empty directory outside the prefix survives a traversing manifest entry"
fi

# ─── an install that copies nothing changes nothing ─────────────────────────
# The prune's own boundary. Its input is "everything the previous manifest lists
# that this run did not install", so a run that installs NOTHING — an unbuilt or
# cleaned $PREFIX — makes the entire previous install an orphan and would delete
# it wholesale. The accumulator being empty is the one input for which the diff
# is meaningless rather than merely large, so both the prune and the manifest
# rewrite are refused.
#
# The disk half is true on the base as well (nothing was ever pruned there); the
# manifest half is not, because the base finalizes the empty accumulator over a
# good manifest and thereby forgets an install that is still on disk — a second
# defect of the same overwrite, reachable without any recipe ever dropping a file.
_case empty
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
rm -rf "${_s:?}/bin" "${_s:?}/lib" "${_s:?}/include"
_empty_out=$(_run_install "$_s" "$_d")
if [ -f "$_d/lib/libmediaforge-keep.a" ] \
   && [ -f "$_d/.mediaforge-manifest" ] \
   && grep -q 'libmediaforge-keep\.a' "$_d/.mediaforge-manifest"; then
  _pass "an install that copies nothing leaves the tree and the manifest intact"
else
  _bad "an install that copies nothing leaves the tree and the manifest intact"
fi

# Leaving them alone silently is indistinguishable from a successful install of
# zero files, and the exit status stays 0 either way, so the warning IS the
# signal. README.md advertises it; assert the thing it advertises.
if printf '%s\n' "$_empty_out" | grep -q 'Nothing was installed'; then
  _pass "an install that copies nothing says so"
else
  _bad "an install that copies nothing says so"
fi

# ─── uninstall after an install-over-install is still pristine ──────────────
# The documented invariant (CLAUDE.md, README.md): an isolated prefix removes
# itself. On a tree without the prune the orphan keeps lib/ non-empty, the
# bottom-up rmdir correctly refuses, and the prefix root is left behind with no
# warning — which is exactly how #15 was found.
_case pristine
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_run_uninstall "$_s" "$_d" >/dev/null
if [ ! -d "$_d" ]; then
  _pass "an isolated prefix removes itself after install-over-install + uninstall"
else
  _bad "an isolated prefix removes itself after install-over-install + uninstall"
fi

printf 'DONE: install-manifest-reconcile\n'
exit "$_fail"
