#!/bin/sh
# The transitive-util .pc exclusion is RECORDED, not enacted on the workspace —
# regression tests for crippledgeek/mediaforge#60.
#
# recipes/ffmpeg.sh used to delete the recipe-declared transitive-util .pc files
# from $PREFIX/lib/pkgconfig once configure had baked their link flags into
# libav*.pc, which left do_install with nothing to decide. It also left the
# workspace unable to build again: the recipes that own those files are stamped,
# so a second build never reinstalls them, and configure resolves the names from
# the system instead. Where a system .pc differs from ours the link probe dies —
# Arch's freetype2.pc omits harfbuzz, so our harfbuzz-enabled libfreetype.a
# links with ~30 undefined hb_* symbols and configure reports whichever library
# it happened to be probing ("libbluray not found"), which is why the diagnosis
# cost a whole session.
#
# The invariant under test is the one the issue asks for: a build must leave the
# workspace in a state from which the next build produces the same result. Two
# behavioural checks drive the real production path (finalize, then do_install
# against a staging prefix) and one derived check says no code anywhere deletes
# from the workspace pkgconfig dir again.
#
# The behavioural checks are COMPOUND, deliberately. "freetype2.pc is still in
# the workspace" is true on the merge base too — the base only deletes it from
# inside recipes/ffmpeg.sh, which a test cannot run without a full build — so
# each is paired with the half the base gets wrong: that the file is installed
# anyway, because the base's install layer has no filter at all.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest — and
# tests/oracle-baseline.sh depends on that, since a file that aborts early
# cannot prove the assertions after the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT INT TERM

# A workspace as recipes/ffmpeg.sh leaves one: an FFmpeg .pc that must be
# installed, a transitive-util .pc that must not be, and the queue the
# transitive-util recipe appended on the way past. .logs exists because
# do_install writes its prefix-rewrite scratch there.
_stage() { # dir
  mkdir -p "$1/bin" "$1/lib/pkgconfig" "$1/.logs" || exit 1
  printf 'FFMPEG-BINARY\n' > "$1/bin/ffmpeg"
  printf 'ARCHIVE\n'       > "$1/lib/libavcodec.a"
  printf 'Name: libavcodec\nVersion: 62.0.0\nLibs: -L%s/lib -lavcodec\n' "$1" \
    > "$1/lib/pkgconfig/libavcodec.pc"
  printf 'Name: FreeType 2\nVersion: 2.14.1\nLibs: -L%s/lib -lfreetype\n' "$1" \
    > "$1/lib/pkgconfig/freetype2.pc"
}

# The build's tail, driven exactly as a build drives it: finalize the queue the
# recipes populated, then install. `command -v` rather than an unconditional
# call because the merge base has no finalize step at all — the point of this
# file is that its absence is visible in the install, not in an abort here.
_finalize_and_install() { # workspace  dest
  PREFIX="$1" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    if command -v pc_exclusions_finalize >/dev/null 2>&1; then
      pc_exclusions_finalize
    fi
    do_install "$1"
  ' _ "$2" 2>&1
}

# ─── the workspace keeps the file, and the install prefix does not ──────────
_ws="$_tmp/keep/workspace"
_dest="$_tmp/keep/dest"
mkdir -p "$_dest" || exit 1
_stage "$_ws"
printf 'freetype2.pc\n' > "$_ws/.pc-skip-queue"
_finalize_and_install "$_ws" "$_dest" >/dev/null

if [ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && [ ! -e "$_dest/lib/pkgconfig/freetype2.pc" ]; then
  _pass excluded-pc-stays-in-the-workspace-and-is-not-installed
else
  _bad excluded-pc-stays-in-the-workspace-and-is-not-installed \
    "workspace copy $([ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && echo kept || echo GONE), installed copy $([ -e "$_dest/lib/pkgconfig/freetype2.pc" ] && echo PRESENT || echo absent)"
fi

# The exclusion has to be a filter, not a blanket skip of the pkgconfig dir, and
# the manifest is the record uninstall acts on — an entry for a file that was
# never copied would make `uninstall` report a deletion it did not perform.
_manifest="$_dest/.mediaforge-manifest"
if [ -f "$_dest/lib/pkgconfig/libavcodec.pc" ] &&
   grep -q 'lib/pkgconfig/libavcodec\.pc' "$_manifest" 2>/dev/null &&
   ! grep -q 'freetype2\.pc' "$_manifest" 2>/dev/null; then
  _pass non-excluded-pc-is-installed-and-only-it-is-recorded
else
  _bad non-excluded-pc-is-installed-and-only-it-is-recorded \
    "$(sed -n '/pkgconfig/p' "$_manifest" 2>/dev/null | tr '\n' ' ')"
fi

# ─── a second build sees the workspace the first one left ───────────────────
# The invariant in its own words. The first install consumed the record; the
# second build re-queues the same name (lib/framework.sh does that before the
# stamp check, so an already-built recipe still queues), and must find the file
# it links against still there.
_finalize_and_install "$_ws" "$_dest" >/dev/null
if [ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && [ ! -e "$_dest/lib/pkgconfig/freetype2.pc" ]; then
  _pass second-install-over-the-same-workspace-agrees-with-the-first
else
  _bad second-install-over-the-same-workspace-agrees-with-the-first \
    "workspace copy $([ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && echo kept || echo GONE), installed copy $([ -e "$_dest/lib/pkgconfig/freetype2.pc" ] && echo PRESENT || echo absent)"
fi

# ─── the traversal guard survived the move out of recipes/ffmpeg.sh ─────────
# Queue entries are recipe-supplied constants, but a typo like
# PKG_PC_FILES="../../something" reaches the record as a name to act on. The
# guard used to sit beside an `rm`; it now sits beside a comparison, and it is
# worth no less there — an entry naming a directory component is a mistake
# whichever way it is read.
#
# Compound for the reason the header gives: "no bogus entry was recorded" is
# vacuously true on a base that records nothing, so the good name has to be
# there too.
_ws2="$_tmp/guard/workspace"
_stage "$_ws2"
printf '../evil.pc\n.hidden.pc\nfreetype2.pc\n' > "$_ws2/.pc-skip-queue"
PREFIX="$_ws2" SCRIPT_DIR="$_root" VERBOSE=0 sh -c '
  . "$SCRIPT_DIR/lib/utils.sh"
  . "$SCRIPT_DIR/lib/install.sh"
  if command -v pc_exclusions_finalize >/dev/null 2>&1; then
    pc_exclusions_finalize
  fi
' >/dev/null 2>&1
_recorded=$(cat "$_ws2/.pc-exclude" 2>/dev/null | tr '\n' ' ')
if [ "$_recorded" = "freetype2.pc " ]; then
  _pass finalize-records-the-declared-name-and-refuses-a-traversing-one
else
  _bad finalize-records-the-declared-name-and-refuses-a-traversing-one \
    "recorded: [$_recorded]"
fi

# ─── nothing deletes from the workspace pkgconfig dir ───────────────────────
# Derived, not listed. The defect was one line in one recipe; the guard has to
# be against the line coming back ANYWHERE, including in a recipe written later
# that decides to tidy the dir on its own account. Comments are stripped so the
# prose above — and in lib/pc-exclusions.sh, which explains the deletion at
# length — is not read as the deletion.
_deleters=''
for _f in mediaforge.sh lib/*.sh recipes/*.sh recipes/*/*.sh; do
  [ -f "$_f" ] || continue
  # [$] rather than a backslash-escaped dollar: the same one character to the
  # ERE, and it keeps the pattern out of shellcheck's "expressions don't expand
  # in single quotes" heuristic without a suppression comment.
  if sed 's/#.*//' "$_f" | grep -qE 'rm[[:space:]]+[^|;&]*[$](PREFIX|[{]PREFIX[}])/lib/pkgconfig'; then
    _deleters="$_deleters $_f"
  fi
done
if [ -z "$_deleters" ]; then
  _pass no-production-code-deletes-from-the-workspace-pkgconfig-dir
else
  _bad no-production-code-deletes-from-the-workspace-pkgconfig-dir \
    "a build that does this leaves a workspace the next build cannot configure against:$_deleters"
fi

# Completion sentinel, read by tests/oracle-baseline.sh: it distinguishes
# "asserted and failed", which is what the gate wants to see from a file
# measuring a change, from "aborted before asserting", which it exists to catch.
printf 'DONE: transitive-util .pc exclusion is durable\n'
exit "$_fail"
