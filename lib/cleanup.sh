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

  # Drop any staged install that never got merged (GH-59). A build that dies
  # inside pkg_install leaves one behind, and nothing else removes it. The
  # stamps are deliberately preserved above; the stage deliberately is not —
  # it is the work of the recipe that just FAILED, so keeping it would leave a
  # half-installed tree waiting to be merged by the next run.
  mf_stage_discard

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
