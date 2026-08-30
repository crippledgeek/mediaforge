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

# User cleanup (clean subcommand).
#
# Two functions because the two directories cost different things to replace,
# and only one of them is ours to reconstruct (GH-71). $PREFIX is rebuildable
# from local state at the price of CPU time. $DISTDIR is a set of tarballs each
# already checked against its .hash sidecar, and refilling it depends on every
# upstream still serving the same bytes at that minute — which this tool neither
# controls nor can retry its way out of. GH-70 is what that costs when it is a
# side effect of a command named "clean".
#
# The split is also the convention everywhere else: ports(7) separates `clean`
# from `distclean`, port-clean(1) makes --work the default and --dist a separate
# request, and makepkg(8) has no option that touches SRCDEST at all.
workspace_cleanup() {
  rm -rf "$PREFIX"
  log "Removed the build tree: $PREFIX"
}

# Built on workspace_cleanup rather than beside it: a second `rm -rf "$PREFIX"`
# here is the copy that stops matching the first one the day either grows a
# guard.
full_cleanup() {
  # Announced BEFORE the removal, following the GNU standards' rule for the one
  # target that deletes what special tools are needed to rebuild — there, a
  # mandated echo; here, the upstreams that may not answer next time.
  warn "Also removing the verified tarball cache: $DISTDIR"
  warn "Refetching it depends on every upstream still serving the same bytes."
  workspace_cleanup
  rm -rf "$DISTDIR"
  log "Cleanup done."
}

# What the default kept, and how to remove it. The workspace-only default is a
# behaviour change for anyone who has been running `clean` to reclaim disk, and
# the output of the command they already run is the only place that reaches
# them.
report_kept_cache() {
  [ -d "$DISTDIR" ] || return 0
  _kept=$(find "$DISTDIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  log "Kept $_kept verified file(s) in $DISTDIR (use 'clean --all' to remove them too)."
}

# Register traps
setup_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
