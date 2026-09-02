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
# workspace in a state from which the next build produces the same result. Most
# checks here drive the real production path -- finalize, or one step of it,
# then do_install against a staging prefix -- and one derived check says no code
# anywhere deletes from the workspace pkgconfig dir again. Kinds, not counts.
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
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

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
# above, so this run takes its missing-queue early return and the install is
# filtered by the record that SURVIVED. That is the behaviour under test here --
# pc_exclusions_finalize's early return, not pc_exclusions_reset, which has its
# own assertion below because nothing else in the tree calls it.
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

# _pc_step <workspace> <function>: one lib/pc-exclusions.sh step, alone, with
# BOTH its diagnostics and its exit status preserved -- the refusals below are
# only refusals if they are non-zero, and only useful if they say why.
#
# The function is passed as an argument rather than named in each of three
# near-identical drivers. The `command -v` guard is what lets this file run
# against a merge base where lib/pc-exclusions.sh does not exist: it exits 0
# having done nothing, which is the wrong answer to every assertion below and
# so fails each of them rather than aborting the file.
_pc_step() { # workspace  function
  PREFIX="$1" SCRIPT_DIR="$_root" VERBOSE=0 sh -c "$_MF_INSTALL_SOURCES"'
    command -v "$1" >/dev/null 2>&1 || exit 0
    "$1"
  ' _ "$2" 2>&1
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
_guard_log=$(_pc_step "$_ws2" pc_exclusions_finalize) || true
_recorded=$(tr '\n' ' ' < "$_ws2/.pc-exclude" 2>/dev/null)
if [ "$_recorded" = "freetype2.pc " ] &&
   printf '%s\n' "$_guard_log" | grep -q '\.\./evil\.pc' &&
   printf '%s\n' "$_guard_log" | grep -q '\.hidden\.pc'; then
  _pass finalize-records-the-declared-name-and-refuses-a-traversing-one-loudly
else
  _bad finalize-records-the-declared-name-and-refuses-a-traversing-one-loudly \
    "recorded: [$_recorded]; said: $(printf '%s' "$_guard_log" | tr '\n' ' ')"
fi

# ─── reset drops the queue and keeps the record ─────────────────────────────
# The other half of the durability claim, and the half nothing else could see:
# pc_exclusions_reset has exactly one caller in the tree (the top of a build)
# and no test, so `rm -f "$PREFIX/.pc-exclude"` added to it would have left
# every other assertion in this file green while making the workspace
# single-use again by a different route.
#
# Both halves, because either alone is satisfiable by doing nothing: a function
# that returns immediately keeps the record, and one that deletes both clears
# the queue.
_ws5="$_tmp/reset/workspace"
_stage "$_ws5"
printf 'freetype2.pc\n' > "$_ws5/.pc-exclude"
printf 'freetype2.pc\n' > "$_ws5/.pc-skip-queue"
_pc_step "$_ws5" pc_exclusions_reset >/dev/null
if [ -f "$_ws5/.pc-exclude" ] && [ ! -e "$_ws5/.pc-skip-queue" ]; then
  _pass reset-drops-the-queue-and-keeps-the-record
else
  _bad reset-drops-the-queue-and-keeps-the-record \
    "record $([ -f "$_ws5/.pc-exclude" ] && echo kept || echo GONE), queue $([ -e "$_ws5/.pc-skip-queue" ] && echo PRESENT || echo dropped)"
fi

# ─── a record is never replaced by a shorter one ────────────────────────────
# The refusals the record's whole value rests on. It is the authority do_install
# trusts, and its failure direction is asymmetric -- a missing name is
# INSTALLED, and shadowing a system library is the outcome this mechanism exists
# to prevent, while a spurious name merely withholds a .pc. So a finalize that
# cannot produce the list the queue asked for has to fail loudly and leave the
# previous list standing, not commit a shorter one and exit 0.
_ws4="$_tmp/refuse/workspace"
_stage "$_ws4"
printf 'freetype2.pc\n' > "$_ws4/.pc-skip-queue"
_pc_step "$_ws4" pc_exclusions_finalize >/dev/null
_good_record=$(cat "$_ws4/.pc-exclude" 2>/dev/null)

# _refuses <assertion-name> <message-fragment>: finalize must refuse, keep the
# record, and say WHICH guard refused.
#
# All three parts are the assertion. Every guard here produces the same
# observable pair -- non-zero exit, record unchanged -- so a check that stops
# there passes with the guard it names deleted, and three of these four did
# exactly that until a reviewer mutation-tested them. The message fragment is
# what makes each one about its own branch.
#
# A function rather than four copies, and NOT a subshell: _bad sets $_fail in
# the caller, and a subshell would drop every failure this file reports.
_refuses() { # assertion-name  message-fragment
  _rf_log=$(_pc_step "$_ws4" pc_exclusions_finalize)
  _rf_rc=$?
  if [ "$_rf_rc" -ne 0 ] &&
     [ "$(cat "$_ws4/.pc-exclude" 2>/dev/null)" = "$_good_record" ] &&
     printf '%s\n' "$_rf_log" | grep -q "$2"; then
    _pass "$1"
  else
    _bad "$1" \
      "rc=$_rf_rc, record now [$(tr '\n' ' ' < "$_ws4/.pc-exclude" 2>/dev/null)], said: $(printf '%s' "$_rf_log" | tr '\n' ' ')"
  fi
}

# Every entry rejected: the queue is not empty, so "nothing to exclude" is not
# what it means -- it means the recipe declarations are wrong, and recording
# zero would silently install every transitive utility from here on.
printf '../evil.pc\n' > "$_ws4/.pc-skip-queue"
_refuses an-all-rejected-queue-refuses-and-keeps-the-previous-record 'was rejected'

# A queue file that exists and is empty. Distinct from the missing-queue early
# return above and from the all-rejected case: nothing was rejected and nothing
# is there, so neither diagnosis fits, and recording zero from it would be the
# same silent shadowing install. An empty queue reaches the all-rejected check
# too -- the read loop appends nothing either way -- which is precisely why the
# message is asserted.
: > "$_ws4/.pc-skip-queue"
_refuses an-empty-queue-refuses-and-keeps-the-previous-record 'exists but is empty'

# The mismatch branch itself, reached by making the measurement disagree with
# the loop. A genuine mid-read I/O fault cannot be induced from a test, but the
# guard's input can: a `wc` on PATH reporting a count the loop cannot have read
# is the same disagreement the fault produces, and it is the only thing this
# branch ever looks at. The suite already shims `sudo` this way in
# tests/install-manifest-reconcile.sh.
#
# PATH is set and restored around the call rather than exported into a subshell,
# because _refuses reports through _bad and a subshell would swallow the result.
# The shim directory holds nothing but `wc`, and nothing else on this path calls
# it -- lib/install.sh's two uses are inside do_install and do_uninstall, and
# _pc_step runs neither.
_wcshim="$_tmp/wcshim"
mkdir -p "$_wcshim" || exit 1
cat > "$_wcshim/wc" <<'SHIM'
#!/bin/sh
# More lines than any queue this test writes, so the counts cannot agree.
printf '%s\n' 99
SHIM
chmod +x "$_wcshim/wc"
printf 'freetype2.pc\n' > "$_ws4/.pc-skip-queue"
_oldpath=$PATH
PATH="$_wcshim:$PATH"
_refuses a-short-read-refuses-and-keeps-the-previous-record 'truncated'
PATH=$_oldpath

# An unreadable queue, which is the real shape of the unchecked-`sort` defect:
# a redirection creates its target before the command runs, so a failure that is
# not checked yields an EMPTY input and a zero-entry record from a queue that
# asked for one.
printf 'freetype2.pc\n' > "$_ws4/.pc-skip-queue"
chmod 000 "$_ws4/.pc-skip-queue"
if [ "$(id -u)" = "0" ]; then
  # Root reads a 0000 file, so the fixture cannot bite. Reported rather than
  # silently skipped: a SKIP prints neither PASS nor FAIL, so the assertion
  # count stays consistent between this tree and the baseline run.
  printf 'SKIP: unreadable-queue refusal (root ignores mode 000)\n'
else
  _refuses an-unreadable-queue-refuses-and-keeps-the-previous-record \
    'Cannot read the .pc exclusion queue'
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
# Continuations are folded through tests/lib-assert.sh's _logical_lines, as
# tests/debug-levels.sh already does for the same reason: `rm -f \` on one line
# with the path on the next is invisible to a raw-line grep, and that is the
# shape a reformatting of the original defect would most naturally take.
#
# RESIDUAL, stated rather than papered over: a path held in a variable
# (`_d=$PREFIX/lib/pkgconfig; rm -f "$_d"/*.pc`) splits the two halves across
# lines and is not caught, and `sed 's/#.*//'` truncates a line carrying a `#`
# inside quotes or a `${VAR#…}` expansion. Catching either needs dataflow, not
# grep. What this does catch is the defect that occurred and every one-line
# rewrite of it.
# $_root passed explicitly. _tree_sh_files defaults its root to $ROOT, which
# every other caller of it sets; this file is the one that spells the variable
# $_root, so the default expanded under `set -u` and the walk aborted -- it
# yielded 0 files where it should yield 131, and the loop below then found no
# deleters because it read no files at all. The assertion reported PASS for the
# whole of its life having scanned nothing.
#
# The floor is what makes that unrepeatable. A search whose corpus can silently
# go empty needs an assertion that the corpus was non-empty, or "found nothing"
# and "looked at nothing" are the same result -- the vacuity guard the suite
# already carries for upstream-provenance and sidecars-in-tree-validate.
_scanned=0
_deleters=''
for _f in $(_tree_sh_files "$_root"); do
  _scanned=$((_scanned + 1))
  if _logical_lines "$_f" | sed 's/#.*//' |
     grep -E '[$](PREFIX|[{]PREFIX[}])/lib/pkgconfig' |
     grep -qE '(^|[[:space:];&|(])(rm|rmdir|unlink|shred|cd)[[:space:]]|-delete|-exec[[:space:]]+rm'; then
    _deleters="$_deleters $_f"
  fi
done
if [ "$_scanned" -lt 100 ]; then
  _bad no-production-code-deletes-from-the-workspace-pkgconfig-dir \
    "the walk scanned $_scanned files -- too few to have covered lib/ and recipes/, so a clean result means nothing"
elif [ -z "$_deleters" ]; then
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
