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
