#!/bin/sh
# A build that reaches the end without a terminal — regression tests for
# crippledgeek/mediaforge#90.
#
# Two independent defects, both visible in one run of
# `./mediaforge.sh build --enable-nonfree --debug < /dev/null` on 2026-09-02:
# all 110 packages built, `workspace/bin/ffmpeg` was produced and worked, and
# the run still exited 1 reporting a package failure that never happened.
#
#   [mediaforge] Build complete. Binaries available at: ...
#     Select [1-3]: [mediaforge] FATAL: Invalid selection
#   [mediaforge] WARNING: Build failed during: unknown
#   [mediaforge] WARNING: Fix the issue and re-run to resume from the failed package.
#
# 1. _select_prefix (lib/install.sh) falls through to `read -r _choice` whenever
#    no --prefix was given and AUTOINSTALL is not yes. On EOF the variable is
#    empty and lands in the `*) die "Invalid selection"` arm, so a closed stdin
#    is reported as a typo. is_interactive() (lib/utils.sh) already answers this
#    question -- it checks AUTOINSTALL, $CI and `[ -t 0 ]` -- and lib/resolve.sh
#    consults it twice; lib/install.sh never did.
#
# 2. on_exit (lib/cleanup.sh) fires on any non-zero status and attributes it to
#    a package unconditionally. _CURRENT_PACKAGE is cleared after every package
#    that finishes -- lib/framework.sh calls `set_current_package ""` at the end
#    of run_recipe -- so an empty value means the failure happened OUTSIDE a
#    package build, exactly the
#    case where "re-run to resume from the failed package" is advice about
#    nothing. The `:-unknown` fallback admits the handler cannot name a package
#    while the two lines around it assert a specific story anyway.
#
# Every assertion below fails on the merge base, which is what
# tests/oracle-baseline.sh requires of an added file. Two of them fold a
# still-works half into the same assertion rather than standing alone -- the
# menu must still appear WITH a terminal, and the resume advice must still be
# printed for a genuine package failure -- because either alone passes on the
# base and would fail the gate for the wrong reason.
#
# No `set -e`: each check reports independently and the file exits with the
# accumulated status, so one failure does not hide the rest.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"
# shellcheck source=tests/lib-install-driver.sh
. "$_root/tests/lib-install-driver.sh"

# do_install with the environment a script or CI job actually has: no --prefix,
# AUTOINSTALL unset, stdin closed. _install_sh cannot drive this -- it hardcodes
# AUTOINSTALL=yes, which is the branch that already works -- so the sources are
# spliced here directly, sharing the dependency list and nothing else.
#
# PREFIX points at a staging tree that does hold a file, so a run that DOES
# install has something to copy and cannot be mistaken for a skip.
_run_headless_install() { # staging-prefix
  PREFIX="$1" INSTALL_MANPAGES=0 SCRIPT_DIR="$_root" VERBOSE=0 \
    sh -c "$_MF_INSTALL_SOURCES"'do_install ""' _ < /dev/null 2>&1
}

# on_exit with a chosen exit status and a chosen _CURRENT_PACKAGE.
#
# `(exit N)` sets $? for the call without leaving the subshell, which is how the
# handler sees a status it did not produce. TOPDIR is set because on_exit cd's
# to it; the cd is already tolerant, but leaving it unset would test a different
# path than the real one.
_run_on_exit() { # exit-status  current-package
  TOPDIR="$_root" SCRIPT_DIR="$_root" VERBOSE=0 \
    sh -c '
      . "$SCRIPT_DIR/lib/utils.sh"
      . "$SCRIPT_DIR/lib/stage.sh"
      . "$SCRIPT_DIR/lib/cleanup.sh"
      _CURRENT_PACKAGE="$2"
      (exit "$1")
      on_exit
    ' _ "$1" "$2" 2>&1
}

_stage=$(mktemp -d) || exit 1
mkdir -p "$_stage/bin"
printf 'FFMPEG-BINARY\n' > "$_stage/bin/ffmpeg"

# One run, read by the three assertions below. $HOME points at a path that does
# not exist yet, so the ~/.local the menu's option 2 would choose is observable
# afterwards: a guard that returned 0 while still copying would satisfy the
# status and message checks and silently install to a prefix nobody chose.
_probe=$(mktemp -d) || exit 1
rmdir "$_probe"
_out=$(HOME="$_probe" _run_headless_install "$_stage")
_status=$?

# ─── a headless install is skipped, not failed, and installs nothing ────────
# The status is the whole point: a build that has already produced its binaries
# must not report failure because nobody was there to answer a menu.
#
# The did-not-install half is folded in rather than standing alone because it
# passes on the base for the wrong reason -- the base dies before it can copy
# anything -- and tests/oracle-baseline.sh fails an added file whose assertion
# passes on the base.
_why=""
[ "$_status" -eq 0 ] || _why="do_install exited $_status with no terminal"
[ ! -e "$_probe/.local" ] || _why="$_why; it created $_probe/.local rather than skipping"
if [ -n "$_why" ]; then
  _bad headless-install-skips-cleanly "${_why#; } -- output: $_out"
else
  _pass headless-install-skips-cleanly
fi
rm -rf "$_probe"

# ─── EOF is not a typo ──────────────────────────────────────────────────────
# Reported separately from the status because the two rot apart: a future guard
# could return 0 while still printing this, and the message is what a reader
# acts on.
case "$_out" in
  *'Invalid selection'*)
    _bad headless-install-not-called-invalid \
      "a closed stdin was reported as an invalid menu selection: $_out" ;;
  *) _pass headless-install-not-called-invalid ;;
esac

# ─── the skip says how to install instead ───────────────────────────────────
# A silent skip is its own defect: the operator asked for a build that installs
# and got one that did not, so the message has to name the three ways to say
# what was meant. --no-install is included because it is the flag that makes the
# skip deliberate, and nothing else advertises it at this point in the run.
_missing=""
for _flag in '--prefix' '-y' '--no-install'; do
  case "$_out" in
    *"$_flag"*) ;;
    *) _missing="$_missing $_flag" ;;
  esac
done
if [ -n "$_missing" ]; then
  _bad headless-install-names-the-escapes \
    "the skip message never names:$_missing; output: $_out"
else
  _pass headless-install-names-the-escapes
fi

# ─── a failure outside a package does not blame one ─────────────────────────
# Four requirements in one assertion, because three of them pass on the base and
# only the pair of absences fails there. Splitting them would hand the oracle
# gate an assertion that passes on the base:
#
#   * with _CURRENT_PACKAGE empty, no resume advice and no "unknown" package
#   * with it empty, a warning is still emitted -- removing the false
#     attribution must not remove the diagnosis with it, or the quieter handler
#     is a silent failure rather than an honest one
#   * with it set, the resume advice is unchanged for a genuine package failure
_outside=$(_run_on_exit 1 '')
_inside=$(_run_on_exit 1 'x265')
_why=""
case "$_outside" in
  *'resume from the failed package'*)
    _why="advised resuming a package build that never failed" ;;
esac
case "$_outside" in
  *'Build failed during: unknown'*)
    _why="$_why; named 'unknown' as the package that failed" ;;
esac
case "$_outside" in
  *WARNING*) ;;
  *) _why="$_why; a failure outside a package produced no warning at all" ;;
esac
case "$_inside" in
  *'resume from the failed package'*) ;;
  *) _why="$_why; a real package failure lost its resume advice" ;;
esac
if [ -n "$_why" ]; then
  _bad on-exit-outside-a-package "${_why#; } -- outside: $_outside"
else
  _pass on-exit-outside-a-package
fi

rm -rf "$_stage"

# Completion sentinel, read by tests/oracle-baseline.sh: it proves this file ran
# to the END on the baseline tree, which is what distinguishes "asserted and
# failed" from "aborted before asserting".
printf 'DONE: non-interactive build\n'
exit "$_fail"
