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
# Split because the things under these two directories do not cost the same to
# replace, and the dividing line is not the directory — it is whether restoring
# something needs an upstream to answer (GH-71).
#
# Reconstructible here, with no network:
#   * $PREFIX          — the build tree, rebuildable at the price of CPU time
#   * $DISTDIR/<dir>/  — sources unpacked from an archive we still hold
#                        (lib/download.sh extracts each one beside its archive)
# Needs an upstream to answer:
#   * $DISTDIR/<file>  — the downloaded archives
#   * $DISTDIR/<dir>/.git — the git clones (every recipe that calls fetch_git)
#
# So the default removes the first group and keeps the second; --all removes
# both. GH-71 records what the old behaviour cost: a full clean discarded the
# cache, one archive host answered with a bot challenge that minute, and the run
# was blocked on a file it had held a verified copy of ten minutes earlier. x264
# is cloned from that same host, which is why the clones are on the keep side of
# the line.
#
# This is also the convention everywhere else, including the part that was
# missing at first: ports(7) `clean` is "Remove the expanded source code" and
# `distclean` is the one that adds the distfiles; port-clean(1) makes --work the
# default and --dist a separate request; makepkg(8) has no option that touches
# SRCDEST at all.
#
# The flag is --all and NOT --dist, which looks backwards beside that sentence
# and is not. Every system above that names a UNION names it with a verb --
# ports and OpenWrt `distclean`, Yocto `cleanall` -- and MacPorts, the only one
# that uses flags, splits the two: `--dist` is "Delete source code archives, the
# so-called distfiles", an additive selector for the distfiles ALONE, while
# `--all` is "Remove all temporary files. The same as specifying --archive,
# --dist, --logs, and --work". Ours removes the build tree, the unpacked
# sources, the archives and the clones together, so it is their --all. Borrowing
# --dist would borrow the word while inverting what it means to anyone who knows
# where it came from.
#
# KEEPING BYTES LONGER IS NOT A TRUST DECISION. A cached archive is re-verified
# against its .hash sidecar on every reuse, not merely when it was first
# fetched — lib/download.sh's fetch() downloads if absent "then verify either
# way (#19)", and both branches call verify_file. What gates reuse is the
# sidecar, never the absence of a cache, so surviving longer does not make a bad
# file more reachable. A refactor that moved verification into the
# download-only branch would break that, and this default is what makes it
# load-bearing.
workspace_cleanup() {
  rm -rf "$PREFIX"
  log "Removed the build tree: $PREFIX"
}

# The unpacked sources, which live in $DISTDIR beside the archives they came
# from. An entry carrying .git is a clone rather than an unpacked archive:
# re-creating it needs the forge, so it stays on the keep side.
#
# The clone test is mf_is_git_clone (lib/utils.sh), which fetch_git calls too --
# see there for why the two must agree and why the predicate is `-d`. It is a
# shared function rather than a repeated `[ -d ... ]` because it was repeated,
# and the repetition had already outgrown the assertion watching it.
#
# Entries that are themselves symlinks are left alone entirely: what one points
# at is not ours to judge, and `rm -rf` on it would remove the link while the
# count claimed a source tree. Dot-entries are invisible to the glob (POSIX `*`
# skips them) and nothing in-tree creates one.
#
# A shell glob rather than `find -maxdepth 1`, which is not POSIX (CLAUDE.md's
# first non-negotiable) and would be this repo's first use of it in lib/. An
# unmatched glob stays literal and fails the -d test, so an empty or absent
# $DISTDIR needs no special case.
# Every top-level entry in $DISTDIR, one at a time, to the function named in $1.
#
# The walk is here rather than in each caller because two of them do it for
# different reasons -- one prunes, one counts -- and the guard and the glob were
# written out twice. The coupling is not cosmetic: which entries the walk can
# SEE is a property of the walk, so the dot-entry gap below is a decision that
# has to reach both callers, and two copies is how one of them gets missed.
#
# POSIX `*` skips dot-entries, and nothing lib/download.sh writes into $DISTDIR
# begins with a dot, so that gap is recorded rather than closed. An unmatched
# glob stays literal, which is why the entry's existence is tested before the
# callback sees it.
mf_each_dist_entry() { # callback
  [ -d "$DISTDIR" ] || return 0
  for _entry in "$DISTDIR"/*; do
    [ -e "$_entry" ] || continue
    "$1" "$_entry"
  done
}

# One entry, pruned if it is an unpacked source tree. A symlink is left alone
# whatever it points at, and a clone belongs to the keep side.
_prune_one_entry() {
  [ -d "$1" ] && [ ! -L "$1" ] && ! mf_is_git_clone "$1" || return 0
  # `${1:?}` for the reason lib/download.sh writes
  # `rm -rf "${DISTDIR:?}/${_dir:?}"`: not because this one can go empty -- it
  # is the shell's own glob expansion and the -d above has already held -- but
  # so a reader does not have to re-derive that before trusting the line.
  rm -rf "${1:?}"
  _pruned=$((_pruned + 1))
}

prune_extracted_sources() {
  _pruned=0
  mf_each_dist_entry _prune_one_entry
  [ "$_pruned" -gt 0 ] || return 0
  log "Removed $_pruned unpacked source tree(s) from $DISTDIR"
}

# What is in $DISTDIR that an upstream would have to serve again, as a phrase,
# or nothing at all when there is none.
#
# ONE counter, because two call sites make a claim about the same set: the
# default says what it kept, and --all says what it is about to discard. Two
# counters would answer the same question differently the first time either
# learned about a new kind of entry.
#
# "cached" and not "verified": --skip-checksum and --skip-checksum=PKG
# short-circuit verify_file (lib/download.sh, checksum_skipped), so an archive
# in here has not necessarily been checked against anything.
_count_one_entry() {
  if [ -f "$1" ]; then
    _downloads=$((_downloads + 1))
  elif mf_is_git_clone "$1"; then
    _clones=$((_clones + 1))
  fi
}

describe_cached_assets() {
  _downloads=0
  _clones=0
  mf_each_dist_entry _count_one_entry
  if [ "$_downloads" -gt 0 ] && [ "$_clones" -gt 0 ]; then
    printf '%s cached download(s) and %s git clone(s)' "$_downloads" "$_clones"
  elif [ "$_downloads" -gt 0 ]; then
    printf '%s cached download(s)' "$_downloads"
  elif [ "$_clones" -gt 0 ]; then
    printf '%s git clone(s)' "$_clones"
  fi
}

# Built on workspace_cleanup rather than beside it: a second `rm -rf "$PREFIX"`
# here is the copy that stops matching the first one the day either grows a
# guard.
full_cleanup() {
  # Named BEFORE the removal. The GNU standards ask the one target that deletes
  # what special tools are needed to rebuild to say so first -- its
  # maintainer-clean commands "should start with" two @echo lines to that
  # effect. A convention rather than a mandate, and the right one here: what
  # this discards is restorable only if an upstream still answers.
  _discarding=$(describe_cached_assets)
  if [ -n "$_discarding" ]; then
    warn "Also removing $_discarding from $DISTDIR"
    warn "Refetching them depends on every upstream still serving the same bytes."
  fi
  workspace_cleanup
  rm -rf "$DISTDIR"
  log "Cleanup done."
}

# What the default kept, and how to remove it. The workspace-only default is a
# behaviour change for anyone who has been running `clean` to reclaim disk, and
# the output of the command they already run is the only place that reaches
# them. Silent when there is nothing kept, rather than advertising a flag that
# would remove nothing.
report_kept_cache() {
  _kept=$(describe_cached_assets)
  [ -n "$_kept" ] || return 0
  log "Kept $_kept in $DISTDIR (use 'clean --all' to remove them too)."
}

# Register traps
setup_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
