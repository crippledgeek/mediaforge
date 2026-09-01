#!/bin/sh
# Core utility functions for mediaforge

# Reduce a string to characters that can only ADD to the terminal, never
# rewrite it. LC_ALL=C keeps the classes byte-defined so the filter cannot vary
# with the operator's locale; `[:print:]` already includes space, so
# `[:blank:]` is here for TAB alone.
#
# The three reporters below interpolate values mediaforge did not choose --
# paths, filenames, tool output, and the operator's own command line. An ESC or
# a CR inside one of those rewrites the very line being read to diagnose a
# problem, which is a diagnostic that lies rather than merely a cosmetic one.
# lib/download.sh's describe_payload had this filter inline for exactly that
# reason (the payload there is chosen by whoever answers the request); it now
# calls this, so the rule exists once.
#
# NEWLINE IS RETAINED. `[:print:]` does not include it, and `tr -d` deletes
# rather than replaces, so stripping it does not merely join two lines -- it
# jams the last word of one against the first of the next ("hash file X:line two
# here"). Nineteen calls across lib/ pass deliberately multi-line text, among
# them fetch_git's three-line tag-vs-commit instruction, and the first version of
# this helper mangled every one of them: a hardening that damaged the operator
# surface it was added to protect. A newline cannot move the cursor back over
# what is already printed, which is the threat here, so it is not the character
# to spend that on. CR and ESC stay deleted.
#
# One `tr` per reported line, and log() is the hot caller rather than run(). A
# full build reports a few thousand lines against hours of compilation, so the
# cost is not measurable -- but it is this function's own cost, not one already
# being paid elsewhere.
#
# The `command -v` is not defensive decoration: tests/ccache.sh runs mediaforge
# under a sandbox PATH holding only the binaries the case is about, and without
# this the filter produced NOTHING there -- so `die` printed "FATAL: " with the
# reason stripped off, and two assertions that read the reason failed. A
# reporter that loses its message is worse than one that prints an unfiltered
# character: die() is what runs when everything else has already gone wrong, and
# a PATH without `tr` is a broken environment rather than an attacker. So the
# message wins, and the filter applies wherever it can. `command -v` is a shell
# builtin, so asking costs no fork.
# CALL SITES ARE ASCII, and that is this filter's cost rather than an accident
# of how the messages happen to be typed. `[:print:]` here is 0x20-0x7E, so
# every byte of a multibyte character is deleted -- an em-dash written into a
# die() leaves the two spaces that surrounded it and nothing between them, which
# is what an operator met on a fresh checkout ("No stamps at ...  run build
# first"). The other spelling, admitting printable multibyte, cannot be had from
# a byte class: C1 controls are 0x80-0x9F and UTF-8 continuation bytes are
# 0x80-0xBF, and U+2014 is E2 80 94 -- both its tail bytes sit inside C1, so no
# `tr` range keeps the dash while dropping a bare CSI. Separating them needs a
# UTF-8 decoder, and it would widen mf_printable_line, whose input is written by
# whoever answers a request. So the strict filter is kept and `--` is written at
# the call sites; tests/output-and-startup-hygiene.sh censuses them, because a
# convention nothing checks is one the next message breaks.
#
# THE RULE BINDS THESE THREE REPORTERS, and nothing else. Text written straight
# to the terminal with printf never passes through here, so it keeps whatever
# characters its author chose -- cmd_check_shadowers' legend in mediaforge.sh,
# lib/menu.sh's option rows, lib/resolve.sh's menu labels. That is why a screen
# can show an ASCII separator from log() directly under an em-dash from printf:
# the two lines went to the terminal by different routes and only one of them is
# filtered. It reads as a half-applied convention and is not one.
mf_printable() {
  if command -v tr >/dev/null 2>&1; then
    printf '%s' "$*" | LC_ALL=C tr -dc '[:print:][:blank:]\n'
  else
    printf '%s' "$*"
  fi
}

# The same filter for text whose author is not us -- what an origin served, or
# what a remote API answered. A retained newline there would let that text forge
# a line of its own, a convincing `[mediaforge] ...` one, inside the very
# diagnostic an operator is reading to decide whether to trust a download. Our
# own messages keep their newlines, because for those the newline is formatting
# and the author is the reader.
#
# FAILS CLOSED, and that is the whole difference from mf_printable. Without `tr`
# this returns nothing rather than the raw string: mf_printable's fail-open trade
# is sound because there the author and the reader are the same local operator,
# and losing a die() message is worse than an unfiltered byte they typed
# themselves. Here the author is remote, so returning raw bytes would drop every
# protection this function was split out to provide -- newline, ESC and CR -- in
# exactly the adversarial case it exists for. The cost of failing closed is one
# missing diagnostic line in an environment with no `tr`, and callers already
# handle empty: describe_payload's `[ -n "$_dp_full" ] || return 0` is the same
# silence-over-a-wrong-answer trade its cap logic already makes.
mf_printable_line() {
  command -v tr >/dev/null 2>&1 || return 0
  mf_printable "$*" | tr -d '\n'
}

# "Is this directory a git clone?" -- asked by fetch_git before it decides a
# destination is reusable, and by lib/cleanup.sh before it decides one is
# prunable. Those two answers MUST agree: a directory cleanup keeps is one
# fetch_git will reuse, and one cleanup prunes is one fetch_git would have
# replaced anyway. They agreed by coincidence while the test was written out at
# three call sites, and a review found the third had already drifted out of
# reach of the assertion meant to watch it.
#
# `-d` and not `-e`: a worktree or submodule checkout has .git as a FILE, which
# this reads as "not a clone". That is deliberate rather than overlooked --
# fetch_git replaces any destination failing this same test, so answering
# otherwise would keep a directory only until the next build, at the cost of the
# two answers disagreeing. Nothing lib/download.sh creates has that shape.
mf_is_git_clone() { [ -d "$1/.git" ]; }

# Logging
log()  { printf '[mediaforge] %s\n' "$(mf_printable "$*")"; }
warn() { printf '[mediaforge] WARNING: %s\n' "$(mf_printable "$*")" >&2; }
die()  { printf '[mediaforge] FATAL: %s\n' "$(mf_printable "$*")" >&2; exit 1; }

# Run a command, capturing output to a log file.
# On success the log is removed. On failure it is printed to stderr.
run() {
  _phase="${_current_phase:-build}"
  _logdir="$PREFIX/.logs"
  _logfile="$_logdir/${PKG_NAME:-unknown}-${_phase}.log"
  mkdir -p "$_logdir" 2>/dev/null

  log "$ $*"
  if [ "${DRY_RUN:-false}" = true ]; then
    return 0
  fi
  if "$@" > "$_logfile" 2>&1; then
    rm -f "$_logfile"
  else
    _rc=$?
    printf '%s\n' "--- build log: $_logfile ---" >&2
    cat "$_logfile" >&2
    die "Command failed (exit $_rc): $*"
  fi
}

# Run a command that reads from stdin (e.g., here-documents)
run_stdin() {
  _phase="${_current_phase:-build}"
  _logdir="$PREFIX/.logs"
  _logfile="$_logdir/${PKG_NAME:-unknown}-${_phase}.log"
  mkdir -p "$_logdir" 2>/dev/null

  log "$ $* < (stdin)"
  if [ "${DRY_RUN:-false}" = true ]; then
    cat >/dev/null
    return 0
  fi
  if "$@" > "$_logfile" 2>&1; then
    rm -f "$_logfile"
  else
    _rc=$?
    printf '%s\n' "--- build log: $_logfile ---" >&2
    cat "$_logfile" >&2
    die "Command failed (exit $_rc): $*"
  fi
}

# Rewrite FILE through an awk program, atomically, and die if either half fails.
#
# `awk prog "$f" > "$f.tmp" && mv "$f.tmp" "$f"` is the idiom this replaces, and
# it drops the status of BOTH halves: nothing sets `set -e`, so a failed awk
# short-circuits the mv and the caller carries on believing it rewrote the file.
# lib/framework.sh's _mf_pc_rewrite already held that line for the eight .pc
# rewrites; lib/makesum.sh's hash_record_write carried the unguarded copy, where
# a failed awk left the sidecar untouched, a `.hash.tmp` behind, and the caller
# going on to WARN that it had updated the digest -- reporting a rewrite that did
# not happen (GH-85).
#
# The tmp file is removed on either failure, so a run that dies leaves no
# half-written sibling for the next run to trip over. EQUIVALENT MUTANT,
# registered rather than re-derived: deleting the `rm -f` in the MV arm survives
# a green suite, because a same-directory `mv` of a file that exists does not
# fail on any filesystem a test can construct. The awk arm's `rm -f` is covered
# twice over.
#
# $3 onwards are passed to awk BEFORE the program, which is what lets a caller
# supply `-v` bindings (hash_record_write passes three) without this needing to
# know anything about them. Values reach awk as arguments rather than by string
# interpolation into the program, so a filename holding an awk metacharacter
# cannot become code.
mf_awk_rewrite() { # file  awk-program  [awk-option...]
  _ar_file="$1"
  _ar_prog="$2"
  shift 2
  _ar_what="${PKG_NAME:+$PKG_NAME: }"
  awk "$@" "$_ar_prog" "$_ar_file" > "$_ar_file.tmp" ||
    { rm -f "$_ar_file.tmp"; die "${_ar_what}failed to rewrite $_ar_file"; }
  mv "$_ar_file.tmp" "$_ar_file" ||
    { rm -f "$_ar_file.tmp"; die "${_ar_what}failed to replace $_ar_file"; }
}

# Command existence check (POSIX — no 'which')
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# pkg-config library check (uses return code, not -x on output)
library_exists() {
  pkg-config --exists "$1" 2>/dev/null
}

# Build stamp gating — check stamp file in $PREFIX/.stamps/
# Stamp filenames encode name and version: .stamps/x264-0.164
# Returns 0 (true) if package should be built, 1 (false) if up to date
stamp_check() {
  _pkg="$1"
  _ver="$2"
  _stampdir="$PREFIX/.stamps"
  _stamp="$_stampdir/${_pkg}-${_ver}"

  log ""
  log "Building $_pkg - version $_ver"
  log "======================="

  if [ -f "$_stamp" ]; then
    log "$_pkg version $_ver already built. Remove $_stamp to rebuild."
    return 1
  fi

  # Check for any older stamp for this package
  for _old_stamp in "$_stampdir/${_pkg}-"*; do
    [ -f "$_old_stamp" ] || continue
    # Found an old version stamp
    if [ "$REBUILD_OUTDATED" = true ]; then
      log "$_pkg is outdated, rebuilding with version $_ver"
      rm -f "$_old_stamp"
      return 0
    else
      log "$_pkg is outdated but will not be rebuilt. Use --rebuild-outdated to rebuild."
      return 1
    fi
  done

  return 0
}

# Mark package as built, recording WHAT was built (GH-59).
#
# The stamp is this project's pkg-plist: one $PREFIX-relative path per line,
# naming the files the staged install produced. It used to be an empty file, and
# an empty file is a claim with no evidence behind it -- which is how three
# stamps came to be missing while their libraries sat in workspace/lib, and how
# the reverse (a stamp outliving its artifact) can make a build skip a recipe it
# never built.
#
# An EMPTY stamp is still valid and still means "built": every stamp written
# before this change is empty, and so is the stamp of a recipe that installs
# nothing at all -- vaapi and waflib, the only two left in a built workspace.
# reconcile reports those as `unverifiable` rather than as drift, which is the
# difference between "no evidence" and "evidence of a problem".
#
# It used to be the state of every recipe installing with a bare shell `cp`
# as well. GH-68 converted those; the category did not disappear, it emptied.
#
# The commit here is what makes the sub-package recipes attribute correctly:
# recipes/audio/lv2.sh builds seven packages inside one pkg_install and calls
# this between them, so each stamp drains exactly the files staged since the
# previous one. It is also what makes each sub-install LIVE before the next
# sub-build configures against it.
stamp_write() {
  _stampdir="$PREFIX/.stamps"
  mkdir -p "$_stampdir" 2>/dev/null
  mf_stage_commit
  mf_stage_pending_extant > "$_stampdir/${1}-${2}"
  mf_stage_pending_reset
}

# Print compiler flags
print_flags() {
  log "CFLAGS: $CFLAGS"
  log "CXXFLAGS: $CXXFLAGS"
  log "LDFLAGS: $LDFLAGS"
  log "LDEXEFLAGS: $LDEXEFLAGS"
}

# Returns 0 if running interactively (TTY on stdin, --yes not set, $CI not set).
is_interactive() {
  [ "${AUTOINSTALL:-}" = "yes" ] && return 1
  [ -n "${CI:-}" ] && return 1
  [ -t 0 ] || return 1
  return 0
}

# Return 0 if the active FFmpeg version (FFMPEG_VERSION) is >= the argument.
# Used by recipes whose FFmpeg configure flag only exists from a given release
# (e.g. --enable-libvvenc requires FFmpeg >= 7.1). Uses an awk field-wise numeric compare (POSIX-portable).
ffmpeg_version_ge() {
  awk -v cur="${FFMPEG_VERSION:-0}" -v min="$1" 'BEGIN {
    n = split(cur, a, "."); m = split(min, b, ".")
    k = (n > m) ? n : m
    for (i = 1; i <= k; i++) {
      av = a[i] + 0; bv = b[i] + 0
      if (av > bv) exit 0
      if (av < bv) exit 1
    }
    exit 0
  }'
}

# Staged installs (GH-59). Sourced HERE rather than left to each caller, for the
# reason lib/install.sh gives about its own dependency: stamp_write above calls
# into it, and a dependency none of the callers names is one none of them can
# forget. mediaforge.sh, the install test drivers and the recipes all reach
# stamp_write through this file.
#
# Sourced at the END so log/warn/die are already defined -- lib/stage.sh calls
# them, and does NOT source this file back.
# shellcheck source=lib/stage.sh
. "$SCRIPT_DIR/lib/stage.sh"
