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
# shellcheck source=tests/lib-install-driver.sh
. "$_root/tests/lib-install-driver.sh"

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
  sh -c "$_MF_INSTALL_SOURCES"'
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
# The invariant in its own words, along the two paths a second build can take.
#
# The re-queue path first: lib/framework.sh queues before the stamp check, so an
# already-built transitive-util recipe still queues its name, and finalize
# rewrites the record from that. The file it links against must still be there.
printf 'freetype2.pc\n' > "$_ws/.pc-skip-queue"
_finalize_and_install "$_ws" "$_dest" >/dev/null
if [ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && [ ! -e "$_dest/lib/pkgconfig/freetype2.pc" ]; then
  _pass requeued-second-install-agrees-with-the-first
else
  _bad requeued-second-install-agrees-with-the-first \
    "workspace copy $([ -f "$_ws/lib/pkgconfig/freetype2.pc" ] && echo kept || echo GONE), installed copy $([ -e "$_dest/lib/pkgconfig/freetype2.pc" ] && echo PRESENT || echo absent)"
fi

# Then the no-op path, which is different code: finalize consumed the queue
# above, so this run returns early and the install is filtered by the record
# that SURVIVED. That survival is the whole durability claim, and it is the one
# thing about pc_exclusions_reset's deliberate refusal to clear the record that
# nothing else pins -- adding `rm -f "$PREFIX/.pc-exclude"` to it leaves every
# other assertion in this file green.
rm -f "$_dest/lib/pkgconfig/freetype2.pc"
_finalize_and_install "$_ws" "$_dest" >/dev/null
if [ -f "$_ws/.pc-exclude" ] && [ ! -e "$_dest/lib/pkgconfig/freetype2.pc" ]; then
  _pass the-record-survives-a-build-that-queues-nothing
else
  _bad the-record-survives-a-build-that-queues-nothing \
    "record $([ -f "$_ws/.pc-exclude" ] && echo kept || echo GONE), installed copy $([ -e "$_dest/lib/pkgconfig/freetype2.pc" ] && echo PRESENT || echo absent)"
fi

# ─── the record, and only the record, decides ───────────────────────────────
# pc_is_excluded's documented fallback: a workspace no build has finished has no
# record, and excludes nothing.
#
# Asserted against the recorded workspace in the SAME breath, because on its own
# this is vacuous -- a tree with no exclusion mechanism at all installs
# freetype2.pc too, and the merge base is exactly that tree. What the base
# cannot do is tell the two workspaces apart.
_ws3="$_tmp/norecord/workspace"
_dest3="$_tmp/norecord/dest"
mkdir -p "$_dest3" || exit 1
_stage "$_ws3"
_finalize_and_install "$_ws3" "$_dest3" >/dev/null
if [ -f "$_dest3/lib/pkgconfig/freetype2.pc" ] &&
   [ -f "$_dest3/lib/pkgconfig/libavcodec.pc" ] &&
   [ ! -e "$_dest/lib/pkgconfig/freetype2.pc" ]; then
  _pass a-workspace-without-a-record-excludes-nothing-one-with-a-record-excludes
else
  _bad a-workspace-without-a-record-excludes-nothing-one-with-a-record-excludes \
    "unrecorded install: $(find "$_dest3/lib/pkgconfig" -name '*.pc' 2>/dev/null | tr '\n' ' ')/ recorded install still has freetype2.pc: $([ -e "$_dest/lib/pkgconfig/freetype2.pc" ] && echo yes || echo no)"
fi

# _finalize_only <workspace>: the build's finalize step alone, with BOTH its
# diagnostics and its exit status preserved -- the refusals below are only
# refusals if they are non-zero, and only useful if they say why.
#
# The `command -v` guard is what lets this file run against a merge base that
# has no finalize step: it exits 0 having done nothing, which is the wrong
# answer to every assertion here and so fails each of them rather than aborting.
_finalize_only() { # workspace
  PREFIX="$1" SCRIPT_DIR="$_root" VERBOSE=0 sh -c "$_MF_INSTALL_SOURCES"'
    command -v pc_exclusions_finalize >/dev/null 2>&1 || exit 0
    pc_exclusions_finalize
  ' 2>&1
}

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
# stderr is KEPT. The module says the rejection is loud, and a silent `continue`
# satisfies every claim about the recorded list while leaving an operator with a
# mis-declared PKG_PC_FILES and nothing to read.
_guard_log=$(_finalize_only "$_ws2") || true
_recorded=$(tr '\n' ' ' < "$_ws2/.pc-exclude" 2>/dev/null)
if [ "$_recorded" = "freetype2.pc " ] &&
   printf '%s\n' "$_guard_log" | grep -q '\.\./evil\.pc' &&
   printf '%s\n' "$_guard_log" | grep -q '\.hidden\.pc'; then
  _pass finalize-records-the-declared-name-and-refuses-a-traversing-one-loudly
else
  _bad finalize-records-the-declared-name-and-refuses-a-traversing-one-loudly \
    "recorded: [$_recorded]; said: $(printf '%s' "$_guard_log" | tr '\n' ' ')"
fi

# ─── a record is never replaced by a shorter one ────────────────────────────
# The two refusals the record's whole value rests on. It is the authority
# do_install trusts, and its failure direction is asymmetric -- a missing name
# is INSTALLED, and shadowing a system library is the outcome this mechanism
# exists to prevent, while a spurious name merely withholds a .pc. So a
# finalize that cannot produce the list the queue asked for has to fail loudly
# and leave the previous list standing, not commit a shorter one and exit 0.
#
# Both are compound with "the record still says what it said", because a
# non-zero exit alone is satisfiable by dying anywhere, including after the mv.
_ws4="$_tmp/refuse/workspace"
_stage "$_ws4"
printf 'freetype2.pc\n' > "$_ws4/.pc-skip-queue"
_finalize_only "$_ws4" >/dev/null
_good_record=$(cat "$_ws4/.pc-exclude" 2>/dev/null)

# Every entry rejected: the queue is not empty, so "nothing to exclude" is not
# what it means -- it means the recipe declarations are wrong, and recording
# zero would silently install every transitive utility from here on.
printf '../evil.pc\n' > "$_ws4/.pc-skip-queue"
_refuse_log=$(_finalize_only "$_ws4")
_refuse_rc=$?
if [ "$_refuse_rc" -ne 0 ] && [ "$(cat "$_ws4/.pc-exclude" 2>/dev/null)" = "$_good_record" ]; then
  _pass an-all-rejected-queue-refuses-and-keeps-the-previous-record
else
  _bad an-all-rejected-queue-refuses-and-keeps-the-previous-record \
    "rc=$_refuse_rc, record now [$(cat "$_ws4/.pc-exclude" 2>/dev/null | tr '\n' ' ')], said: $(printf '%s' "$_refuse_log" | tr '\n' ' ')"
fi

# An unreadable queue, which is the real shape of the unchecked-`sort` defect:
# a redirection creates its target before the command runs, so a failure that
# is not checked yields an EMPTY input and a zero-entry record from a queue
# that asked for one.
printf 'freetype2.pc\n' > "$_ws4/.pc-skip-queue"
chmod 000 "$_ws4/.pc-skip-queue"
if [ "$(id -u)" = "0" ]; then
  # Root reads a 0000 file, so the fixture cannot bite. Reported rather than
  # silently skipped: a SKIP prints neither PASS nor FAIL, so it stays
  # consistent between this tree and the baseline run.
  printf 'SKIP: unreadable-queue refusal (root ignores mode 000)\n'
else
  _unreadable_log=$(_finalize_only "$_ws4")
  _unreadable_rc=$?
  if [ "$_unreadable_rc" -ne 0 ] && [ "$(cat "$_ws4/.pc-exclude" 2>/dev/null)" = "$_good_record" ]; then
    _pass an-unreadable-queue-refuses-and-keeps-the-previous-record
  else
    _bad an-unreadable-queue-refuses-and-keeps-the-previous-record \
      "rc=$_unreadable_rc, record now [$(cat "$_ws4/.pc-exclude" 2>/dev/null | tr '\n' ' ')], said: $(printf '%s' "$_unreadable_log" | tr '\n' ' ')"
  fi
fi
chmod 600 "$_ws4/.pc-skip-queue" 2>/dev/null

# ─── nothing deletes from the workspace pkgconfig dir ───────────────────────
# Derived, not listed. The defect was one line in one recipe; the guard has to
# be against the line coming back ANYWHERE, including in a recipe written later
# that decides to tidy the dir on its own account.
#
# Two questions of every production file: does a logical line NAME the workspace
# pkgconfig dir, and does that same line delete or `cd`? The verb list covers
# the rewrites of the original that a reviewer would otherwise have to think of
# — `find … -delete`, `-exec rm`, `unlink`, and the `cd` that makes a relative
# `rm` reach the dir without naming it again.
#
# Continuations are folded through tests/lib-assert.sh's _logical_lines, which
# was written for exactly this and had no second user: `rm -f \` on one line
# with the path on the next is invisible to a raw-line grep, and that is the
# shape a reformatting of the original defect would most naturally take.
#
# RESIDUAL, stated rather than papered over: a path held in a variable
# (`_d=$PREFIX/lib/pkgconfig; rm -f "$_d"/*.pc`) splits the two halves across
# lines and is not caught, and `sed 's/#.*//'` truncates a line carrying a `#`
# inside quotes or a `${VAR#…}` expansion. Catching either needs dataflow, not
# grep. What this does catch is the defect that occurred and every one-line
# rewrite of it.
_deleters=''
for _f in mediaforge.sh lib/*.sh recipes/*.sh recipes/*/*.sh; do
  [ -f "$_f" ] || continue
  if _logical_lines "$_f" | sed 's/#.*//' |
     grep -E '[$](PREFIX|[{]PREFIX[}])/lib/pkgconfig' |
     grep -qE '(^|[[:space:];&|(])(rm|rmdir|unlink|shred|cd)[[:space:]]|-delete|-exec[[:space:]]+rm'; then
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
