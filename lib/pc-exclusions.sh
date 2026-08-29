# shellcheck shell=sh
# Transitive-utility .pc exclusion — one owner for both halves of GH-7.
#
# A handful of recipes (zlib, freetype2, harfbuzz, fontconfig, ...) exist only
# so FFmpeg can link against a known-good copy of a library the host also
# ships. Their .pc files must reach FFmpeg's configure, and must NOT reach the
# install prefix, where they would shadow the system's own. Each such recipe
# declares PKG_TRANSITIVE_UTIL=true and lib/framework.sh queues its .pc names
# here on the way past — even for an already-stamped recipe, so the queue
# describes the build rather than the subset of it that recompiled.
#
# The exclusion is RECORDED, not enacted on the workspace. recipes/ffmpeg.sh
# used to delete the queued files from $PREFIX/lib/pkgconfig once configure had
# baked their link flags into libav*.pc, which left the install layer with
# nothing to decide. It also left the workspace unable to build again (GH-60):
# the recipes that own those files are stamped, so a second build never
# reinstalls them, configure resolves the names from the system instead, and
# where a system .pc differs from ours the link probe fails — Arch's
# freetype2.pc omits harfbuzz, so our harfbuzz-enabled libfreetype.a links with
# ~30 undefined hb_* symbols and configure blames whichever library it happened
# to be probing at the time.
#
# So finalize writes the list to $PREFIX/.pc-exclude and leaves the files
# alone, and do_install (lib/install.sh) consults it. The workspace is then a
# stable, rebuildable input rather than a one-shot artifact, which is the
# invariant GH-60 asks for: a build must leave the workspace in a state from
# which the next build produces the same result.

# Accumulated across the build by pc_exclusions_queue, consumed by
# pc_exclusions_finalize. Transient: reset at the start of every build.
PC_SKIP_QUEUE_NAME=.pc-skip-queue
# The finalized answer of the last completed FFmpeg build, read at install
# time. Durable: survives the build that wrote it, and is overwritten rather
# than appended by the next one.
PC_EXCLUDE_NAME=.pc-exclude

# Drop the accumulator so this build's queue describes this build.
#
# The finalized list is deliberately NOT dropped here. A build that dies before
# recipes/ffmpeg.sh leaves the previous build's answer standing, which is the
# only answer anyone has; clearing it would make an install after a failed
# build ship the shadowing .pc files that the last good build excluded.
pc_exclusions_reset() {
  rm -f "$PREFIX/$PC_SKIP_QUEUE_NAME" 2>/dev/null || :
}

# pc_exclusions_queue <name>...: queue each bare .pc name (no extension).
pc_exclusions_queue() {
  for _pcq_name in "$@"; do
    printf '%s.pc\n' "$_pcq_name" >> "$PREFIX/$PC_SKIP_QUEUE_NAME"
  done
}

# Turn the queue into the durable exclusion list. A no-op when no recipe
# queued anything, which leaves any previous list untouched for the reason
# given in pc_exclusions_reset.
pc_exclusions_finalize() {
  _pcf_queue="$PREFIX/$PC_SKIP_QUEUE_NAME"
  [ -f "$_pcf_queue" ] || return 0

  # Written aside and moved into place, so a reader never sees a half-written
  # list: an install racing a build would otherwise under-exclude and ship a
  # shadowing .pc. The name carries the pid because two builds sharing one
  # workspace is a thing a user can do, not a thing we prevent.
  _pcf_tmp="$PREFIX/$PC_EXCLUDE_NAME.$$"
  : > "$_pcf_tmp" || die "Cannot write the .pc exclusion list at $_pcf_tmp"

  _pcf_count=0
  # sort -u collapses the duplicates that two recipes declaring the same .pc
  # produce — freetype2.sh and freetype2-harfbuzz.sh both own freetype2.pc.
  sort -u "$_pcf_queue" > "$_pcf_tmp.in"
  while IFS= read -r _pcf_name; do
    [ -z "$_pcf_name" ] && continue
    # Path-traversal guard. Entries are recipe-supplied constants, but a typo
    # like PKG_PC_FILES="../../something" would reach do_install as a name to
    # match against, and an entry naming a directory component is a mistake
    # whichever way it is read. Rejected loudly rather than passed through.
    case "$_pcf_name" in
      */* | .*) warn "Ignoring suspicious .pc exclusion entry: $_pcf_name"; continue ;;
    esac
    printf '%s\n' "$_pcf_name" >> "$_pcf_tmp"
    _pcf_count=$((_pcf_count + 1))
  done < "$_pcf_tmp.in"
  rm -f "$_pcf_tmp.in"

  mv "$_pcf_tmp" "$PREFIX/$PC_EXCLUDE_NAME" ||
    die "Cannot install the .pc exclusion list at $PREFIX/$PC_EXCLUDE_NAME"
  rm -f "$_pcf_queue"
  log "  recorded $_pcf_count transitive-util .pc file(s) as not-for-install"
}

# pc_is_excluded <name.pc>: true when the last completed build recorded this
# .pc as a transitive utility. False when no list exists — an install against a
# workspace no build has finished excludes nothing, which is the same answer
# the old delete-from-the-workspace mechanism gave.
pc_is_excluded() {
  [ -f "$PREFIX/$PC_EXCLUDE_NAME" ] || return 1
  grep -qxF -- "$1" "$PREFIX/$PC_EXCLUDE_NAME"
}
