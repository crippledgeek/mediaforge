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
#
# Sourced here rather than left to the caller, on the same argument lib/install.sh
# makes about this file: log()/warn()/die() are this module's dependency, and a
# dependency it does not name is one every caller has to remember. lib/utils.sh
# is nothing but function definitions, so re-sourcing it is free.
# shellcheck source=lib/utils.sh
. "$SCRIPT_DIR/lib/utils.sh"

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

# pc_exclusions_queue <names>: queue a recipe's .pc names, given as one
# space-separated list of bare names (no extension) — the shape PKG_PC_FILES
# already has. The split lives here rather than at the call site because the
# format is this module's, and because an unquoted argument list at the caller
# is what SC2086 exists to catch.
pc_exclusions_queue() {
  for _pcq_name in $1; do
    printf '%s.pc\n' "$_pcq_name" >> "$PREFIX/$PC_SKIP_QUEUE_NAME"
  done
}

# Turn the queue into the durable exclusion list.
#
# The list is the authority do_install trusts, and its failure direction is
# asymmetric: a MISSING name is installed, which is the shadowing this whole
# mechanism exists to prevent, while a spurious name merely withholds a .pc.
# So every way of producing a shorter list than the queue asked for is fatal,
# and the previous list is left standing rather than replaced by a wrong one.
pc_exclusions_finalize() {
  _pcf_queue="$PREFIX/$PC_SKIP_QUEUE_NAME"
  if [ ! -f "$_pcf_queue" ]; then
    # Reached only after a successful FFmpeg build, so "no recipe queued
    # anything" is a real answer and an empty list would be the honest record
    # of it. It is not written, because the same state is also what a bug in
    # the queueing would look like, and between the two readings the previous
    # build's list is the safe one: withholding a .pc costs a downstream
    # consumer a pkg-config lookup, installing one shadows a system library.
    # Said out loud rather than returned silently — nothing else would.
    warn "No transitive-util .pc files were queued this build; keeping the previous exclusion record"
    return 0
  fi

  # Written aside and moved into place, so a reader never sees a half-written
  # list: an install racing a build would otherwise under-exclude and ship a
  # shadowing .pc. The name carries the pid because two builds sharing one
  # workspace is a thing a user can do, not a thing we prevent.
  _pcf_tmp="$PREFIX/$PC_EXCLUDE_NAME.$$"
  # printf, not `: >`. `:` is a POSIX SPECIAL built-in, and POSIX XCU 2.8.1
  # makes a redirection error on one fatal to a non-interactive shell — so
  # `: > f || die` never reaches its die, and the operator gets the shell's
  # message instead of ours. Confirmed here on dash and on bash in POSIX mode;
  # plain bash runs the `||` arm, which is exactly why this cannot be found by
  # running it under bash.
  printf '' > "$_pcf_tmp" || die "Cannot write the .pc exclusion list at $_pcf_tmp"

  _pcf_count=0
  _pcf_seen=0
  # sort -u collapses the duplicates that two recipes declaring the same .pc
  # produce — freetype2.sh and freetype2-harfbuzz.sh both own freetype2.pc.
  # Checked, because a redirection creates the target before the command runs:
  # an unchecked failure here yields an EMPTY input, a zero-entry list, and an
  # install that shadows every system library this mechanism protects.
  sort -u "$_pcf_queue" > "$_pcf_tmp.in" || {
    rm -f "$_pcf_tmp" "$_pcf_tmp.in"
    die "Cannot read the .pc exclusion queue at $_pcf_queue"
  }
  while IFS= read -r _pcf_name; do
    _pcf_seen=$((_pcf_seen + 1))
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

  # `read` reports EOF and a read ERROR the same way, by returning non-zero, so
  # a loop that ended early looks exactly like one that finished. Counting what
  # went in against what came out is what tells them apart, and it closes the
  # class rather than the empty case: a truncation that happens to leave one
  # entry standing passes a survivor count and is the same shadowing install.
  #
  # sort terminates its output with a newline, so wc -l and the loop count the
  # same things and a well-formed queue cannot trip this.
  _pcf_in=$(wc -l < "$_pcf_tmp.in" | tr -d ' ') || {
    rm -f "$_pcf_tmp" "$_pcf_tmp.in"
    die "Cannot measure the .pc exclusion queue at $_pcf_queue"
  }
  rm -f "$_pcf_tmp.in"
  if [ "$_pcf_in" -eq 0 ]; then
    rm -f "$_pcf_tmp"
    die "The .pc exclusion queue at $_pcf_queue exists but is empty; refusing to record an empty exclusion list"
  fi
  if [ "$_pcf_seen" -ne "$_pcf_in" ]; then
    rm -f "$_pcf_tmp"
    die "Read $_pcf_seen of $_pcf_in queued .pc name(s); refusing to record a truncated exclusion list"
  fi

  # A queue with entries that yields no list is the failure this function must
  # not commit: it would replace a good record with an empty one and turn every
  # later install into a shadowing install, reporting success as it went.
  if [ "$_pcf_count" -eq 0 ]; then
    rm -f "$_pcf_tmp"
    die "Every entry in $_pcf_queue was rejected; refusing to replace the .pc exclusion record with an empty one"
  fi

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
