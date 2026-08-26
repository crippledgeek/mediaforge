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
# Every assertion here is COMPOUND, deliberately. tests/oracle-baseline.sh
# requires that no assertion passes on the merge base, and each half that proves
# the prune is conservative — a foreign file survives, a traversing entry is
# refused, a still-shipped file is kept — is true on the base as well, where
# nothing is pruned at all. Pairing each with a removal the base fails to
# perform is what keeps the safety half asserted without buying a free pass.
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

# Driven in a separate `sh` rather than a ( ) subshell, matching
# tests/install-containment.sh: do_install reads PREFIX/AUTOINSTALL from the
# environment, and shadowing this script's own PREFIX inside a subshell would
# both confuse the reader and leak install.sh's functions into the assertions.
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
  printf 'KEPT-LIB\n'      > "$1/lib/libmediaforge-keep.a"
  printf 'DROPPED-LIB\n'   > "$1/lib/libmediaforge-drop.a"
  printf 'HEADER\n'        > "$1/include/mediaforge-probe.h"
  printf 'DROPPED-HEADER\n' > "$1/include/drop/mediaforge-drop.h"
}

# The newer "version": the same stage with the two files the recipe no longer
# ships. Mirrors recipes/other/lcevc.sh dropping the split archives.
_drop_from_stage() {
  rm -f "$1/lib/libmediaforge-drop.a" "$1/include/drop/mediaforge-drop.h"
  rmdir "$1/include/drop" 2>/dev/null || :
}

# ─── an install-over-install removes what the new build no longer ships ─────
# Compound with the kept archive: "libmediaforge-keep.a is still there" is true
# on the base too, where nothing is removed at all.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
if [ ! -e "$_d/lib/libmediaforge-drop.a" ] && [ -f "$_d/lib/libmediaforge-keep.a" ]; then
  _pass "a dropped static archive is pruned on reinstall, the kept one survives"
else
  _bad "a dropped static archive is pruned on reinstall, the kept one survives"
fi

# The manifest is the record uninstall acts on, so the prune has to be visible
# there as well as on disk. Paired with the kept entry for the same reason.
if [ -f "$_d/.mediaforge-manifest" ] \
   && ! grep -q 'libmediaforge-drop\.a' "$_d/.mediaforge-manifest" \
   && grep -q 'libmediaforge-keep\.a' "$_d/.mediaforge-manifest" \
   && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass "the finalized manifest records the kept file and not the pruned one"
else
  _bad "the finalized manifest records the kept file and not the pruned one"
fi

# A directory the prune empties is collected, like the bottom-up sweep
# do_uninstall already runs. Paired with the surviving sibling header.
if [ ! -d "$_d/include/drop" ] && [ -f "$_d/include/mediaforge-probe.h" ]; then
  _pass "a directory emptied by the prune is removed, its sibling header is not"
else
  _bad "a directory emptied by the prune is removed, its sibling header is not"
fi
rm -rf "$_s" "$_d"

# ─── the prune touches nothing mediaforge did not install ───────────────────
# The shared-prefix case (~/.local, /usr/local): a file the manifest never
# listed is not ours to remove, however it got there.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
printf 'NOT-OURS\n' > "$_d/lib/libsomeone-else.a"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
if [ -f "$_d/lib/libsomeone-else.a" ] && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass "a file mediaforge never installed survives the prune"
else
  _bad "a file mediaforge never installed survives the prune"
fi
rm -rf "$_s" "$_d"

# ─── a traversing entry in the OLD manifest is refused ──────────────────────
# The prune reads a file that lives inside the install prefix and drives `rm -f`
# from it, under sudo for a system prefix. That is the same trust boundary
# do_uninstall guards at its own read, so the same refusal has to apply here —
# on the copy of the manifest that was on disk BEFORE this run, which is the one
# an earlier compromise could have edited.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_outside=$(mktemp -d) || exit 1
printf 'OUTSIDE\n' > "$_outside/escape-probe"
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
printf '../%s/escape-probe\n' "$(basename "$_outside")" >> "$_d/.mediaforge-manifest"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
if [ -f "$_outside/escape-probe" ] && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass "a traversing entry in the previous manifest is skipped by the prune"
else
  _bad "a traversing entry in the previous manifest is skipped by the prune"
fi
rm -rf "$_s" "$_d" "$_outside"

# ─── an install that copies nothing changes nothing ─────────────────────────
# The prune's own boundary. Its input is "everything the previous manifest lists
# that this run did not install", so a run that installs NOTHING — an unbuilt or
# cleaned $PREFIX — makes the entire previous install an orphan and would delete
# it wholesale. The accumulator being empty is the one input for which the diff
# is meaningless rather than merely large, so both the prune and the manifest
# rewrite are refused.
#
# Both halves are asserted. The disk half is true on the base as well (nothing
# was ever pruned there); the manifest half is not, because the base finalizes
# the empty accumulator over a good manifest and thereby forgets an install that
# is still on disk — a second defect of the same overwrite, reachable without
# any recipe ever dropping a file.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
rm -rf "${_s:?}/bin" "${_s:?}/lib" "${_s:?}/include"
_run_install "$_s" "$_d" >/dev/null 2>&1
if [ -f "$_d/lib/libmediaforge-keep.a" ] \
   && [ -f "$_d/.mediaforge-manifest" ] \
   && grep -q 'libmediaforge-keep\.a' "$_d/.mediaforge-manifest"; then
  _pass "an install that copies nothing leaves the tree and the manifest intact"
else
  _bad "an install that copies nothing leaves the tree and the manifest intact"
fi
rm -rf "$_s" "$_d"

# ─── uninstall after an install-over-install is still pristine ──────────────
# The documented invariant (CLAUDE.md, README.md): an isolated prefix removes
# itself. On a tree without the prune the orphan keeps lib/ non-empty, the
# bottom-up rmdir correctly refuses, and the prefix root is left behind with no
# warning — which is exactly how #15 was found.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null 2>&1
_run_uninstall "$_s" "$_d" >/dev/null 2>&1
if [ ! -d "$_d" ]; then
  _pass "an isolated prefix removes itself after install-over-install + uninstall"
else
  _bad "an isolated prefix removes itself after install-over-install + uninstall"
fi
rm -rf "$_s" "$_d"

printf 'DONE: install-manifest-reconcile\n'
exit "$_fail"
