#!/bin/sh
# Core utility functions for mediaforge

# Logging
log()  { printf '[mediaforge] %s\n' "$*"; }
warn() { printf '[mediaforge] WARNING: %s\n' "$*" >&2; }
die()  { printf '[mediaforge] FATAL: %s\n' "$*" >&2; exit 1; }

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
# Path of a recipe's build stamp. One definition, because run_recipe needs to
# ask whether a stamp exists before deciding to trust a recorded build input.
stamp_path() {
  printf '%s\n' "$PREFIX/.stamps/${1}-${2}"
}

# True when the recipe is already built.
stamp_exists() {
  [ -f "$(stamp_path "$1" "$2")" ]
}

stamp_check() {
  _pkg="$1"
  _ver="$2"
  _stamp=$(stamp_path "$_pkg" "$_ver")
  _stampdir="$PREFIX/.stamps"

  log ""
  log "Building $_pkg - version $_ver"
  log "======================="

  if stamp_exists "$_pkg" "$_ver"; then
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

# Mark package as built by creating a stamp file
stamp_write() {
  _stampdir="$PREFIX/.stamps"
  mkdir -p "$_stampdir" 2>/dev/null
  : > "$_stampdir/${1}-${2}"
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
