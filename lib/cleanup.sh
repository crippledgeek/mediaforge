#!/bin/sh
# Trap handlers and cleanup

# Track state for trap handler
_CURRENT_PACKAGE=""

# Called by framework when starting a package
set_current_package() {
  _CURRENT_PACKAGE="$1"
}

# Main trap handler — runs on EXIT, INT, TERM
on_exit() {
  _exit_code=$?

  if [ "$_exit_code" -ne 0 ]; then
    warn "Build failed during: ${_CURRENT_PACKAGE:-unknown}"
    warn "Successfully built packages are preserved (stamp files intact)."
    warn "Fix the issue and re-run to resume from the failed package."
  fi

  # Restore working directory
  cd "$TOPDIR" 2>/dev/null || true

  exit "$_exit_code"
}

# User cleanup (clean subcommand)
full_cleanup() {
  rm -rf "$DISTDIR"
  rm -rf "$PREFIX"
  log "Cleanup done."
}

# Register traps
setup_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
