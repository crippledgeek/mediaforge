#!/bin/sh
# Core utility functions for mediaforge

# Logging
log()  { printf '[mediaforge] %s\n' "$*"; }
warn() { printf '[mediaforge] WARNING: %s\n' "$*" >&2; }
die()  { printf '[mediaforge] FATAL: %s\n' "$*" >&2; exit 1; }

# Execute a command with logging and error checking
execute() {
  log "$ $*"
  _output=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_output"
    die "Command failed (exit $_rc): $*"
  fi
}

# Execute a command that reads from stdin (e.g., here-documents)
execute_stdin() {
  log "$ $* < (stdin)"
  _output=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_output"
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

# Directory helpers
make_dir() {
  remove_dir "$1"
  mkdir -p "$1" || die "Failed to create directory $1"
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -rf "$1"
  fi
}

# Build gating — check done-file
# Returns 0 (true) if package should be built, 1 (false) if already done
build() {
  _pkg="$1"
  _ver="$2"

  log ""
  log "Building $_pkg - version $_ver"
  log "======================="

  if [ -f "$DISTDIR/$_pkg.done" ]; then
    _done_ver=$(cat "$DISTDIR/$_pkg.done")
    if [ "$_done_ver" = "$_ver" ]; then
      log "$_pkg version $_ver already built. Remove $DISTDIR/$_pkg.done to rebuild."
      return 1
    elif [ "$REBUILD_OUTDATED" = true ]; then
      log "$_pkg is outdated, rebuilding with version $_ver"
      return 0
    else
      log "$_pkg is outdated but will not be rebuilt. Use --latest to rebuild."
      return 1
    fi
  fi

  return 0
}

# Mark package as built
build_done() {
  printf '%s\n' "$2" > "$DISTDIR/$1.done"
}

# Print compiler flags
print_flags() {
  log "CFLAGS: $CFLAGS"
  log "CXXFLAGS: $CXXFLAGS"
  log "LDFLAGS: $LDFLAGS"
  log "LDEXEFLAGS: $LDEXEFLAGS"
}
