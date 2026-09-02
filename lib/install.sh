#!/bin/sh
# Install/uninstall mediaforge-built FFmpeg binaries and libraries.
#
# Install layer copies the workspace pkgconfig dir minus the transitive
# utilities (fontconfig, harfbuzz, freetype2, ...), which would shadow the
# system's own. Which names those are is not decided here: each is declared
# by the recipe that owns it (PKG_TRANSITIVE_UTIL=true), recorded by
# recipes/ffmpeg.sh once configure has consumed them, and read back through
# pc_is_excluded. The intent stays in the recipe layer where the author knows
# it — no central distro-flavored stop-list — and the workspace keeps the
# files, so it can be built from again (GH-60). See lib/pc-exclusions.sh.

# Sourced here rather than left to the caller: the exclusion record is an
# implementation detail of the pkgconfig loop below, and mediaforge.sh and every
# install test driver source this file by hand. A dependency none of them names
# is one none of them can forget. No count is written down: the count this
# paragraph replaced was already false on the commit that wrote it, which added
# a sourcer while asserting the old total, and tests/lib-assert.sh records the
# same census drifting twice in three commits.
# shellcheck source=lib/pc-exclusions.sh
. "$SCRIPT_DIR/lib/pc-exclusions.sh"

# ─── Helpers ──────────────────────────────────────────────────────────

# Nearest EXISTING ancestor of $1, probed under the optional privilege $2
# ("sudo", or empty). Lexical: the answer is a path that exists, not a resolved
# one — _resolve_existing does that part.
#
# The privilege matters to the PROBE, not just to the resolution. `test -d`
# answers as whoever runs it, so asked unprivileged about a component inside a
# root-owned 0700 prefix it says "not a directory" for a directory that is
# there, and the walk stops one or more levels too high. The caller then vets an
# ancestor and learns nothing about the symlink below it.
#
# $2 reaches a COMMAND-WORD position unvalidated here — _resolve_existing, the
# only caller, rejects anything but ''|sudo before calling. A second caller must
# validate the same way or move that check down into this function.
_nearest_existing() {
  while ! ${2-} test -d "$1" && [ "$1" != "/" ]; do
    set -- "$(dirname "$1")" "${2-}"
  done
  printf '%s\n' "$1"
}

# Resolve a path ($1) to its PHYSICAL location, under the optional privilege $2,
# by walking to the nearest existing ancestor and resolving that. `cd`/`pwd -P`
# only answer for paths that exist, and install destinations frequently do not
# yet.
#
# Ask under the SAME privilege the write will use, or the answer does not
# describe the write: a prefix this user cannot traverse resolves to nothing
# unprivileged, and `cd` is as blind to it as `test -d` is above.
#
# Prints nothing (and returns non-zero) when nothing in the chain resolves, so
# callers must treat an empty result as "unknown", never as "matches".
#
# `cd ... && pwd -P` rather than `readlink -f`: -f is a GNU extension that
# macOS's readlink has historically lacked, and this must work on both.
_resolve_existing() {
  _re_priv="${2-}"
  case "$_re_priv" in
    ''|sudo) ;;
    # The branch below names sudo literally, so anything else would silently be
    # escalated as sudo. _select_prefix only ever produces these two.
    *) die "internal: _resolve_existing given an unsupported privilege prefix '$_re_priv'" ;;
  esac

  _re_dir=$(_nearest_existing "$1" "$_re_priv")

  if [ -n "$_re_priv" ]; then
    # `sudo` written literally rather than as "$_re_priv": ShellCheck parses the
    # script of an `sh -c` only when the command word is a literal, and an
    # unparsed one is reported as SC2016 instead of being checked. The `case`
    # above is what keeps the literal honest.
    sudo sh -c 'cd "$1" 2>/dev/null && pwd -P' _ "$_re_dir"
  else
    (cd "$_re_dir" 2>/dev/null && pwd -P)
  fi
}

# Detect if we need privilege escalation to install into $1.
#
# POSIX `test -w` returns false on nonexistent paths, so a naive
# `[ ! -w "$target" ]` always elevates for fresh prefixes whose parent the
# user owns. Canonical fix: walk up to the first existing ancestor and
# check ITS writability — that answers "can the current process create
# this tree?" rather than "does this path already exist and is it writable?".
#
# That walk is _resolve_existing's, and this function used to carry its own
# copy of it. Two copies of one idea drift: this one answered on the LEXICAL
# ancestor, so the privilege decision and the containment decision in
# _install_file were reasoning about different paths whenever a symlink was in
# the chain.
#
# Short-circuits when we are already root. Dies (rather than returning a
# misleading "no priv needed") if the target is not writable AND sudo is
# absent — installing as the current user would then fail mid-stream.
_needs_priv() {
  _np_target="$1"

  case "$_np_target" in
    /*) ;;
    *) die "Install prefix must be an absolute path: $_np_target" ;;
  esac
  # Reject '..' segments: they let an attacker-supplied prefix bypass the
  # ancestor-walk privilege decision by resolving to a different filesystem
  # location than the lexical path suggests.
  case "$_np_target" in
    */../*|*/..) die "Install prefix must not contain '..': $_np_target" ;;
  esac

  # Already root: sudo would reset env for no benefit.
  [ "$(id -u)" = "0" ] && return 1

  # Deliberately UNPRIVILEGED — this function is what decides whether privilege
  # is needed, so it cannot borrow it. An ancestor that exists but cannot be
  # entered therefore resolves to nothing, and that is the "not mine to write"
  # answer rather than an error: a root-owned 0700 prefix is precisely what the
  # sudo path below is for. Answering "no privilege needed" is the one thing it
  # must not do.
  _np_ancestor=$(_resolve_existing "$_np_target")

  if [ -n "$_np_ancestor" ] && [ -w "$_np_ancestor" ]; then
    return 1
  fi

  if ! command_exists sudo; then
    die "Cannot write to '$_np_target' and sudo is not available. " \
        "Re-run as root or choose a user-writable prefix."
  fi
  return 0
}

# Read a privileged helper's TEXT into _helper_text, for a caller that will run
# it as `$_priv sh -c "$text"`. Both helpers are read this way, so the two
# refusals below exist once rather than once each.
#
# Assigns to a fixed name instead of printing, because a caller writing
# `x=$(_load_helper_text ...)` would run die() inside a command substitution,
# where it exits the SUBSHELL and leaves the caller running with an empty
# helper — the exact state the emptiness check exists to prevent.
#
# Emptiness is a refusal, not a curiosity: a script with no commands exits 0
# under POSIX, so an empty or truncated helper is indistinguishable from one
# that did the work, and every caller here treats status 0 as "it happened".
_load_helper_text() {
  _helper_text=$(cat "$1") \
    || die "Cannot read the privileged helper at $1"
  [ -n "$_helper_text" ] \
    || die "The privileged helper at $1 is empty."
}

# Place a file AND record it: $1 source, $2 destination, $3 the manifest
# accumulator, $4 the privilege. Everything about the placing is _place_file's;
# this adds the one line that makes the file removable later.
#
# The accumulator lives in /tmp (user-writable regardless of $_install_prefix
# ownership). Without that split, root-owned prefixes silently corrupt the
# manifest, because the >> below is plain shell I/O and is NOT gated by $_priv.
#
# The recorded path is relative to $_install_prefix — the string the user named,
# not the resolved boundary. Both name the same tree, and uninstall resolves the
# prefix itself before composing anything onto it, so the entries stay portable
# across a prefix whose path acquires or loses a symlink between runs.
_install_file() {
  # Positionals used directly on both sides of the call: POSIX restores a
  # function's own $1..$n when a function it called returns, so neither needed
  # saving. Saving one and not the other read as though one of them did.
  _place_file "$1" "$2" "$4"
  printf '%s\n' "${2#"$_install_prefix"/}" >> "$3"
}

# Place ONE file, with every privileged step in one process, and record nothing.
# This is _install_file minus the manifest line — split out because the manifest
# itself has to be written this way too, and it is the one file that must NOT
# appear in its own record.
#
# Reads $_install_prefix_real, which do_install resolves once after creating the
# prefix: it is the containment BOUNDARY, it cannot change mid-install, and
# resolving it per file would put back an exec the helper below exists to avoid.
# Each DESTINATION is still resolved per file, inside that helper.
#
# Before the split the finalize did its own `$_priv rm -f "$_manifest"` followed
# by `$_priv cp`, with a comment explaining that the unlink-first and
# check-the-copy guards "have to be repeated here". Repeating a guard is how the
# copies drift, and that pair was also the last privileged WRITE composing a
# path from a boundary resolved 270 lines earlier and never re-checked. Routed
# through here, it gets the same resolve-immediately-before-acting that every
# other installed file gets.
_place_file() {
  _src="$1"
  _dest="$2"
  _priv="$3"

  # Consumed at entry, not left for the caller to clear. The override applies to
  # exactly ONE call, and taking it here makes that true by construction rather
  # than by a set/clear pair a future caller has to remember to write.
  #
  # The CLEAR specifically is unpinned, and honestly so: the only setter is the
  # manifest finalize, which is the last thing do_install does, so within one
  # process nothing runs afterwards that could observe a stale value. Mutating
  # the clear away changes no assertion. It is here for the second caller, not
  # for today's. The capture and the use are both pinned, by
  # tests/install-containment.sh's failed-manifest-write assertion.
  _pf_context="${_place_context:-}"
  _place_context=""

  # Belt-and-braces against the irreversible path: _select_prefix already
  # refuses an install prefix that resolves to the build prefix, which is the
  # guard that catches aliases. This one costs a line.
  #
  # Ahead of the containment check because it is the cheaper refusal and needs
  # nothing resolved.
  [ "$_src" = "$_dest" ] && return 0

  # ONE privileged process does all of it — resolve, contain, mkdir, unlink,
  # copy — because five sudo calls per file is what made re-checking every file
  # look expensive enough to trade away (#23). lib/install-one-file.sh carries
  # the reasoning and the guarantees; what matters here is that no verdict is
  # ever reused between files, and that the whole thing costs one exec.
  #
  # The helper's TEXT is read once per process and passed to `sh -c`, rather
  # than the helper being run from its path under sudo. Running it by path would
  # re-read the file from disk under root once per installed file — ~250 chances
  # per install for the executed text to differ from the text this install
  # started with. One unprivileged read, before the first copy, is one chance.
  #
  # Read lazily rather than at source time so that sourcing lib/install.sh stays
  # free of I/O for callers that never install (uninstall, the option parser).
  if [ -z "${_install_helper:-}" ]; then
    _load_helper_text "$SCRIPT_DIR/lib/install-one-file.sh"
    _install_helper=$_helper_text
  fi

  # Under $_priv, so the check answers about the same filesystem view the copy
  # gets: a root-owned 0700 prefix is invisible to an unprivileged `cd`, which is
  # the divergence #21 was about.
  #
  # Exit codes carry the outcome back, because the messages belong out here with
  # die(): 3 unresolvable, 4 bad usage, 5 copy failed, 6 outside the prefix
  # (resolved path on stdout). The helper avoids every status the shell itself
  # can produce, so 1/2/126/127 below mean the helper failed to run or to parse
  # rather than anything it decided. Status 0 is necessary but NOT sufficient —
  # see the sentinel check.
  _helper_out=$($_priv sh -c "$_install_helper" _ \
    "$_src" "$_dest" "$_install_prefix_real")
  _install_rc=$?

  case "$_install_rc" in
    # Status 0 alone would also be what a helper mangled down to nothing
    # returns, having checked nothing and copied nothing. The sentinel is
    # printed only after the copy reported success, so requiring it is what
    # makes "installed" mean installed.
    0)
      [ "$_helper_out" = "INSTALLED" ] \
        || die "the install helper reported success for '$_dest' without
  completing -- no INSTALLED sentinel. The helper text may be truncated or
  altered; check $SCRIPT_DIR/lib/install-one-file.sh." ;;
    6) die "install destination '$_dest' resolves to '$_helper_out', outside the
  install prefix '$_install_prefix_real'. Refusing a privileged write through a
  symlink. Check for a symlinked component under the prefix." ;;
    # `sh` returns 2 for a syntax error, so this is a helper damaged in the
    # middle of a construct — the truncation the INSTALLED sentinel cannot
    # catch, because the script never runs far enough to print anything. The
    # containment refusal deliberately does NOT use 2, so the two can never be
    # confused: an operator told to hunt a symlink over a damaged file loses the
    # time twice.
    2) die "the install helper failed to parse while installing '$_dest'
  (exit 2). Its text is truncated or altered; check
  $SCRIPT_DIR/lib/install-one-file.sh." ;;
    3) die "cannot resolve the install destination '$_dest' -- refusing to write." ;;
    5) if [ -n "$_pf_context" ]; then
         die "$_pf_context"
       fi
       die "failed to install $_dest (source: $_src).
  Nothing is at that path now -- the previous file, if any, was removed before
  the copy. Re-run install once the cause is fixed." ;;
    4) die "internal: lib/install-one-file.sh rejected its arguments for '$_dest'.
  A destination with a trailing slash is one cause: it names a directory, and
  this installs files." ;;
    # The helper never ran at all. sudo refusing to execute sh exits 1, an
    # unreadable helper 126, a missing one 127 — none of which reach the arms
    # above, so a restricted sudoers policy surfaced as 'exited 1' with nothing
    # to act on. That diagnosis used to hang off exit 3, where it can no longer
    # arrive: exit 3 now means the destination did not resolve, a different
    # problem with a different fix.
    1|126|127) die "could not run the install helper for '$_dest' (status $_install_rc).
  For a privileged prefix this runs '$_priv sh -c' over
  $SCRIPT_DIR/lib/install-one-file.sh, which a sudoers policy permitting only
  mkdir/cp/rm will refuse -- that is one cause. A missing or unreadable helper is
  the other.
  A root install needs no per-file elevation at all and is the way past a
  policy like that: re-run the whole command as root -- from a root shell, or
  through a sudoers entry for this script, since a policy that refuses sh
  refuses 'sudo ./mediaforge.sh' just as readily. For example
  'sudo ./mediaforge.sh install --prefix=$_install_prefix'. Do that only for a
  SYSTEM prefix: as root into a user-owned one it leaves root-owned files
  behind. Scoping an entry to the helper instead is not available -- it reaches
  sh as text, not as a path, so there is no command name to name." ;;
    *) die "internal: the install helper for '$_dest' exited $_install_rc" ;;
  esac

}

# ─── Prefix Selection ────────────────────────────────────────────────

# Present interactive menu or use provided prefix
# Sets _install_prefix and _priv
_select_prefix() {
  _install_prefix=""
  _priv=""
  # Whether a prefix was chosen at all, as its own answer rather than as this
  # function's exit status. Overloading the status would make EVERY future
  # non-zero return from here -- including one that means a genuine error --
  # read as "nothing to install, carry on", which is the opposite of what an
  # error should do. One named state cannot be mistaken for the other.
  _install_skipped=no

  # --prefix overrides menu
  if [ -n "$_cli_prefix" ]; then
    _install_prefix="$_cli_prefix"
  elif [ "$AUTOINSTALL" = "yes" ]; then
    # Auto mode: user prefix for non-root, system for root
    if [ "$(id -u)" = 0 ]; then
      _install_prefix="/usr/local"
    else
      _install_prefix="$HOME/.local"
    fi
  elif ! is_interactive; then
    # No terminal: a script, a CI job, a background run. `read` would take EOF
    # as an answer and the catch-all arm below would report it as a typo, so a
    # build that has already produced its binaries would exit non-zero for
    # having nobody to ask (GH-90).
    #
    # is_interactive rather than a second `[ -t 0 ]` here: it already folds in
    # AUTOINSTALL and $CI, and lib/resolve.sh consults it at both of its own
    # prompts. A private check would be a fourth answer to one question.
    #
    # Skipped rather than defaulted. Choosing a prefix on the operator's behalf
    # writes ~1500 files somewhere they did not name, and --prefix, -y and
    # --no-install each say what was meant -- so the message names all three.
    warn "Not a terminal -- skipping the post-build install."
    warn "Use --prefix=PATH or -y to install without prompting, or --no-install"
    warn "to skip it deliberately."
    _install_skipped=yes
    return 0
  else
    printf '\n'
    printf '  Install location:\n'
    printf '    1) System   /usr/local     %s\n' "$([ ! -w /usr/local ] && printf '(requires sudo)' || printf '')"
    printf '    2) User     ~/.local\n'
    printf '    3) Other    enter custom path\n'
    printf '\n'
    printf '  Select [1-3]: '
    read -r _choice
    case "$_choice" in
      1) _install_prefix="/usr/local" ;;
      2) _install_prefix="$HOME/.local" ;;
      3)
        printf '  Path: '
        read -r _install_prefix
        if [ -z "$_install_prefix" ]; then
          die "No path provided"
        fi
        ;;
      *) die "Invalid selection" ;;
    esac
  fi

  # Strip a trailing slash. "$_install_prefix"/* is matched against the baked
  # openssldir below; with a trailing slash the pattern becomes '<prefix>//*',
  # which does not match '<prefix>/etc/ssl', and the CA bundle would be skipped
  # silently on nothing worse than how the user typed --prefix.
  while :; do
    case "$_install_prefix" in
      */) _install_prefix="${_install_prefix%/}" ;;
      *)  break ;;
    esac
  done

  # Installing into the build prefix would copy the workspace onto itself: every
  # destination is its own source. _install_file guards the individual copy, but
  # the operation as a whole is meaningless and its failure modes are all bad,
  # so refuse it here where the message can say why.
  # Compared RESOLVED, not lexically. A symlink, a bind mount, or simply a
  # second path into the same tree names the build prefix without matching its
  # string — and then every $_src/$_dest pair is lexically distinct too, so
  # _install_file's own guard misses it as well and the unlink deletes the
  # source through the alias. The CA-bundle destination check further down
  # already refuses to trust a lexical match for exactly this reason; this
  # guard was written without it.
  #
  # Only when the destination EXISTS: a path that is not there cannot be an
  # alias of one that is, and resolving a nonexistent --prefix to its nearest
  # existing ancestor would wrongly refuse --prefix="$PREFIX/sub", which is
  # unusual but harmless (different files, no self-copy).
  if [ -d "$_install_prefix" ]; then
    _ip_real=$(_resolve_existing "$_install_prefix")
    _pfx_real=$(_resolve_existing "$PREFIX")
    if [ -n "$_ip_real" ] && [ "$_ip_real" = "$_pfx_real" ]; then
      die "--prefix resolves to the build prefix ($_pfx_real). Install copies the
  workspace to a destination; copying it onto itself would delete the build tree
  in place. Choose a different prefix, e.g. --prefix=\$HOME/.local/mediaforge."
    fi
  fi

  # Determine privilege escalation
  if _needs_priv "$_install_prefix"; then
    _priv="sudo"
  else
    _priv=""
  fi
}

# ─── Manifest-driven removal ─────────────────────────────────────────

# Act on a manifest through lib/remove-listed-files.sh: MODE 'files' deletes
# what the list names, MODE 'dirs' collects the directories that emptied. $2 is
# the list, $3 the RESOLVED target prefix.
#
# Sets _mr_removed to what THIS invocation removed — files in 'files' mode,
# directories in 'dirs' mode. Read it before the next call overwrites it; both
# callers report the file count, so both read it between their two calls.
#
# Reads $_priv from the caller's scope, like _install_file reads
# $_install_prefix_real: both callers set it from the prefix's ownership, and it
# is the same value for every entry in a run.
#
# ONE process does all of it, for both of the reasons lib/install-one-file.sh
# does the same on the write side. The list is opened by that process, so a
# root-owned 0600 manifest is readable — do_uninstall used to open it with plain
# shell redirection as the invoking user, which on a system prefix silently read
# nothing and reported "Removed 0 files" having removed none. And containment is
# checked by entering each directory and deleting relative to it, rather than by
# rejecting '..' in the text and hoping no component is a symlink.
#
# Shared by do_install's prune and do_uninstall rather than written twice: they
# apply the same rules to the same file format, and a guard living in one copy
# is a guard that stops existing the next time only the other copy is edited.
_remove_manifest_entries() {
  _mr_mode="$1"
  _mr_list="$2"
  _mr_target_real="$3"

  # Read lazily and once per process, exactly like the install helper: running
  # it from its path under sudo would re-read the file from disk as root once
  # per call, and each read is a chance for the executed text to differ from the
  # text this run started with.
  if [ -z "${_remove_helper:-}" ]; then
    _load_helper_text "$SCRIPT_DIR/lib/remove-listed-files.sh"
    _remove_helper=$_helper_text
  fi

  _mr_out=$($_priv sh -c "$_remove_helper" _ "$_mr_mode" "$_mr_target_real" "$_mr_list")
  _mr_rc=$?

  case "$_mr_rc" in
    0) ;;
    2) die "the removal helper failed to parse (exit 2). Its text is truncated or
  altered; check $SCRIPT_DIR/lib/remove-listed-files.sh." ;;
    3) die "cannot resolve '$_mr_target_real' -- refusing to remove anything under it." ;;
    4) die "internal: lib/remove-listed-files.sh rejected its arguments
  (mode '$_mr_mode', list '$_mr_list')." ;;
    7) die "cannot open the manifest at '$_mr_list' -- refusing to report a sweep
  that removed nothing over files that are still there. Check that it is
  readable$([ -n "$_priv" ] && printf ' by root' || printf ' by you')." ;;
    1|126|127) die "could not run the removal helper (status $_mr_rc).
  For a privileged prefix this runs '$_priv sh -c' over
  $SCRIPT_DIR/lib/remove-listed-files.sh, which a sudoers policy permitting only
  mkdir/cp/rm will refuse -- that is one cause. A missing or unreadable helper is
  the other. Re-running the whole command as root needs no per-file elevation." ;;
    *) die "internal: the removal helper exited $_mr_rc" ;;
  esac

  # Status 0 alone is also what a helper mangled down to nothing returns, having
  # checked nothing and removed nothing. Requiring the sentinel is what makes
  # "removed 0 files" mean the list really held nothing left to remove.
  # The digits are part of the contract, not just the word: `_mr_removed` is
  # used in an arithmetic test by the caller, so a mangled helper printing
  # "REMOVED x" would get past a looser pattern and surface as a shell error
  # instead of the diagnostic this arm exists to give.
  # Rejected before accepted, because `[0-9]*` in a case pattern is "one digit
  # then anything" — `*` is unrestricted, not digit-only — so it would admit
  # "REMOVED 5garbage". Nothing eval's this value, so the consequence is a
  # `test: integer expression expected` instead of a diagnostic naming the
  # helper; the reject arm is what makes the contract say what it means.
  case "$_mr_out" in
    'REMOVED '*[!0-9]*) die "the removal helper printed a malformed count
  ('$_mr_out'). Its text may be truncated or altered; check
  $SCRIPT_DIR/lib/remove-listed-files.sh." ;;
    'REMOVED '[0-9]*) _mr_removed="${_mr_out#REMOVED }" ;;
    *) die "the removal helper reported success without completing -- no REMOVED
  sentinel. Its text may be truncated or altered; check
  $SCRIPT_DIR/lib/remove-listed-files.sh." ;;
  esac
}

# ─── Install ─────────────────────────────────────────────────────────

do_install() {
  _cli_prefix="$1"

  # "No prefix was chosen" is a state _select_prefix sets, not a status it
  # returns -- see there for why. A build that has already produced its
  # binaries stays successful when there was nobody to ask (GH-90).
  _select_prefix
  [ "$_install_skipped" = no ] || return 0

  log "Installing to $_install_prefix ..."

  # Create the prefix tree up-front so subsequent $_priv cp's into
  # subdirectories don't fail when the tree doesn't yet exist.
  $_priv mkdir -p "$_install_prefix" || die "Cannot create $_install_prefix"

  # Resolved once, here, and read by every _install_file call as the containment
  # boundary. After the mkdir above, so the prefix itself always resolves and a
  # first install is not measured against its parent.
  #
  # Resolved under $_priv, like every per-destination resolution below it: the
  # copies run under that privilege, so the check has to see what they will see.
  # A root-owned 0700 prefix is invisible to an unprivileged `cd`, and vetting
  # it unprivileged would refuse a legitimate install rather than protect it.
  _install_prefix_real=$(_resolve_existing "$_install_prefix" "$_priv")
  [ -n "$_install_prefix_real" ] \
    || die "Cannot resolve the install prefix '$_install_prefix' after creating it."

  # Composed onto the RESOLVED prefix, not the string the user typed: this path
  # is written under $_priv below, through the same _place_file every installed
  # file goes through, so the boundary it is composed onto has to be the
  # resolved one rather than the string the user typed.
  _manifest="$_install_prefix_real/.mediaforge-manifest"
  # Manifest accumulator lives in /tmp so unprivileged appends always work,
  # even when $_install_prefix is root-owned. mktemp uses O_EXCL — closes the
  # PID-predictable symlink-race window of a bare `/tmp/<name>.$$`.
  # Finalised by _place_file at the end of this function.
  _manifest_tmp=$(mktemp /tmp/mediaforge-manifest.XXXXXX) \
    || die "Cannot create manifest tmp file in /tmp"

  # Binaries
  for _bin in ffmpeg ffprobe ffplay; do
    if [ -f "$PREFIX/bin/$_bin" ]; then
      _install_file "$PREFIX/bin/$_bin" "$_install_prefix/bin/$_bin" "$_manifest_tmp" "$_priv"
      $_priv chmod 755 "$_install_prefix/bin/$_bin"
      log "  bin/$_bin"
    fi
  done

  # Static libraries
  for _lib in "$PREFIX/lib/"*.a; do
    [ -f "$_lib" ] || continue
    _name=$(basename "$_lib")
    _install_file "$_lib" "$_install_prefix/lib/$_name" "$_manifest_tmp" "$_priv"
    log "  lib/$_name"
  done

  # pkgconfig files (rewrite prefix), minus the transitive utilities the
  # build recorded per each recipe's PKG_TRANSITIVE_UTIL declaration. The
  # skip is by NAME against that record rather than by absence from the dir:
  # the files stay in the workspace so the next build can link against them.
  for _pc in "$PREFIX/lib/pkgconfig/"*.pc; do
    [ -f "$_pc" ] || continue
    _name=$(basename "$_pc")
    if pc_is_excluded "$_name"; then
      log "  lib/pkgconfig/$_name (skipped -- transitive utility)"
      continue
    fi
    _tmppc="$PREFIX/.logs/_pc_rewrite_$$"
    awk -v old="$PREFIX" -v new="$_install_prefix" '{gsub(old, new)} {print}' "$_pc" > "$_tmppc"
    _install_file "$_tmppc" "$_install_prefix/lib/pkgconfig/$_name" "$_manifest_tmp" "$_priv"
    rm -f "$_tmppc"
    log "  lib/pkgconfig/$_name"
  done

  # Trust store. Only the libressl arm stages one (recipes/crypto/libressl.sh),
  # and it is the arm with no ENVIRONMENT override at all — libtls bakes an
  # absolute TLS_DEFAULT_CA_FILE at compile time and reads no SSL_CERT_FILE, so
  # unlike the openssl arm the compiled-in path is its only default. Without
  # this copy the bundle lives only in $PREFIX, which `clean` deletes.
  #
  # BOTH inputs come from .mediaforge-choices, the file that already persists
  # every resolved choice. The arm decides whether to ship a bundle at all; the
  # openssldir decides where. Reading the openssldir is not optional: the
  # resolver is a pure function, so it reproduces the build's answer only if it
  # is given the build's inputs, and `install` is a separate process where
  # nothing else carries them. cmd_install does not call load_stored_choices,
  # so without this read OPENSSLDIR is empty here and the probe silently
  # returns a different answer than the build baked.
  #
  # Parsed by name with _stored_choice, never sourced -- and neither is the
  # build's own read of this file. $PREFIX is where every dependency's
  # `make install` writes, so anything that can compromise a build can leave
  # shell here for a later process to execute; asking for values by name means a
  # setting nobody asked for cannot arrive at all. That matters most right here,
  # because this function runs mkdir and cp under sudo for a system prefix. The
  # value read below is additionally put through _validate_openssldir before it
  # reaches _install_file, so what a privileged command receives is an absolute
  # path with no shell metacharacter and no '..' segment.
  #
  # A stale bundle from a previous arm is ignored rather than deleted: reading
  # the arm cannot damage a workspace, and deleting build state from an
  # installer can.
  _stored_tls=""
  _stored_od=""
  if [ -f "$PREFIX/.mediaforge-choices" ]; then
    # Same by-name parser load_stored_choices uses (lib/resolve.sh), rather
    # than a second pair of extraction expressions here: the quoting
    # save_stored_choices applies is a property of the writer, and two readers
    # that each re-derive it drift the first time it changes.
    _stored_tls=$(_stored_choice "$PREFIX/.mediaforge-choices" STORED_TLS_BACKEND)
    _stored_od=$(_stored_choice "$PREFIX/.mediaforge-choices" STORED_OPENSSLDIR)
  fi
  if [ -n "$_stored_od" ]; then
    _validate_openssldir "STORED_OPENSSLDIR (from $PREFIX/.mediaforge-choices)" \
      "$_stored_od" "It is used as a privileged install destination."
  fi
  if [ -f "$PREFIX/etc/ssl/cert.pem" ] && [ "$_stored_tls" = "libressl" ]; then
    resolve_openssldir "$_stored_od" "$PREFIX/etc/ssl"
    _baked="$OPENSSLDIR_RESOLVED"
    case "$_baked" in
      "$_install_prefix"/*)
        # The documented workflow: the user baked the install location, so put
        # the bundle exactly where the binary will look for it.
        _ca_dest="$_baked/cert.pem"
        ;;
      "$PREFIX"/*)
        # Baked at the staging prefix, which `clean` removes. Ship the bundle so
        # it survives, but it is NOT at the baked path — verification needs
        # -ca_file, or a rebuild with --openssldir set to the install prefix.
        _ca_dest="$_install_prefix/etc/ssl/cert.pem"
        warn "CA bundle installed to $_ca_dest, but the binary looks for"
        warn "  $_baked/cert.pem (the build prefix, which 'clean' deletes)."
        warn "  Use -ca_file, or rebuild with --openssldir=$_install_prefix/etc/ssl"
        ;;
      *)
        # A host trust store (probed, or given explicitly). The host owns it —
        # installing our snapshot over it is exactly what the libressl install
        # hook was patched out for. Said out loud: silence here is
        # indistinguishable from the bundle having been forgotten.
        _ca_dest=""
        log "  (CA bundle not installed: the build trusts $_baked, which the host owns)"
        ;;
    esac
    if [ -n "$_ca_dest" ]; then
      # No containment check here any more: _install_file resolves every
      # destination against the prefix before it creates anything, so this path
      # gets the same guard the other five classes now get. The copy that used
      # to live here is what #21 was filed about — it protected the newest
      # destination and only that one.
      _install_file "$PREFIX/etc/ssl/cert.pem" "$_ca_dest" "$_manifest_tmp" "$_priv"
      log "  ${_ca_dest#"$_install_prefix"/} (CA bundle)"
    fi
  fi

  # Headers
  if [ -d "$PREFIX/include" ]; then
    # find's output goes through a FILE, not a pipe into `while`. A pipeline puts
    # the loop body in a subshell, where `die` exits only that subshell: a header
    # destination refused by the containment guard would abort the loop and the
    # install would carry on to finalize a manifest and report success. The
    # refusal has to be able to end the run, like it does for every other class.
    #
    # The list lives in the build prefix's .logs, alongside the pkgconfig
    # rewrite temp below, NOT in /tmp: a containment refusal mid-loop exits the
    # process through die(), so the rm below is unreachable on exactly the path
    # that matters, and a leak inside $PREFIX is one `clean` removes. A trap is
    # not the answer here — mediaforge.sh installs on_exit as the EXIT handler
    # (lib/cleanup.sh's setup_traps) and a local trap would replace it.
    #
    # Unlike the manifest accumulator, this file never outlives the build
    # prefix's own ownership: $PREFIX is the tree we just built as this user,
    # while the manifest's destination may be root-owned.
    mkdir -p "$PREFIX/.logs" || die "Cannot create $PREFIX/.logs"
    _hdrlist="$PREFIX/.logs/_install_headers_$$"
    (cd "$PREFIX/include" && find . -type f) > "$_hdrlist" \
      || die "Cannot list the headers under $PREFIX/include"
    while IFS= read -r _hdr; do
      _hdr="${_hdr#./}"
      _install_file "$PREFIX/include/$_hdr" "$_install_prefix/include/$_hdr" "$_manifest_tmp" "$_priv"
    done < "$_hdrlist"
    rm -f "$_hdrlist"
    log "  include/ (headers)"
  fi

  # Man pages
  if [ "$INSTALL_MANPAGES" = 1 ] && [ -d "$PREFIX/share/man/man1" ]; then
    for _man in "$PREFIX/share/man/man1"/ff*; do
      [ -f "$_man" ] || continue
      _name=$(basename "$_man")
      _install_file "$_man" "$_install_prefix/share/man/man1/$_name" "$_manifest_tmp" "$_priv"
    done
    if command_exists "mandb"; then
      $_priv mandb -q 2>/dev/null
    fi
    log "  share/man/man1/ (man pages)"
  fi

  # An accumulator with nothing in it means this run copied nothing — an empty
  # or unbuilt $PREFIX, most likely. Finalizing it would replace a good manifest
  # with an empty one and make `uninstall` a no-op over a tree that is really
  # there, which is the same end state the copy-check below exists to prevent;
  # reconciling against it would be worse still, since every entry in the
  # previous manifest is then an orphan and the prune would delete the whole
  # install. Both are skipped, out loud: silence here is indistinguishable from
  # a successful install.
  #
  # `return 0`, not `die`: `build` runs this as its last step and still has to
  # reach the skipped-checksum banner afterwards, and an empty workspace is a
  # state to report rather than a failure of the install itself. The exit status
  # therefore stays 0, so a scripted `install && ...` proceeds — the warning is
  # the whole signal. Say so out loud rather than leaving a caller to discover it.
  if [ ! -s "$_manifest_tmp" ]; then
    rm -f "$_manifest_tmp"
    warn "Nothing was installed to $_install_prefix -- no files found in $PREFIX."
    warn "  The existing installation and its manifest are left untouched."
    warn "  Run './mediaforge.sh build' first."
    return 0
  fi

  # Reconcile against the previous manifest before replacing it (#15).
  #
  # do_install only ever copies IN. A file an older build shipped and the
  # current one no longer does — a renamed library, a merged archive, a dropped
  # recipe — stays on disk, and overwriting the manifest destroys the only
  # record that it was ever installed. `uninstall` iterates the manifest and
  # nothing else, so from that point the file is invisible to it permanently:
  # the prefix root survives an uninstall that reports success, and a stale .a
  # can still be picked up by a downstream static link. V-Nova's split lcevc
  # archives are the instance that surfaced it (eight files, 1.4M, after 829b927
  # merged them into one), but any recipe that changes its installed file set
  # has the same shape.
  #
  # Read under $_priv, like every other access to the prefix here: a system
  # install writes this file as root:root 0600, so an unprivileged read would
  # find nothing and prune nothing on exactly the prefixes where an orphan
  # matters most. A read that fails for any reason is the "no previous install"
  # answer — the conservative one, since it prunes nothing.
  #
  # LC_ALL=C on both the sorts and the comm: `comm` requires its inputs sorted
  # in ITS collation, and a locale-sorted input silently yields wrong set
  # differences rather than an error.
  #
  # The comparison is over the manifest's exact TEXT, one line per installed
  # file, as _install_file writes it. Anything that changes how that line is
  # spelled — the prefix-stripping, whitespace, a field added — makes every
  # entry written by the old spelling fail to match its new one and become an
  # orphan, so the install that re-installed a file would then delete it. A
  # format change needs a migration here, not just at the writer.
  #
  # The intermediates live in $PREFIX/.logs, NOT /tmp, following the header-list
  # temp below: a `die` in this block exits through cleanup.sh's EXIT trap and
  # the `rm -f` at the end of the block is unreachable, so a leak wants to land
  # somewhere `clean` removes. The manifest accumulator is in /tmp for a reason
  # that does not apply to these — its destination may be root-owned, while
  # every write here is plain unprivileged redirection into the build prefix we
  # just built as this user.
  mkdir -p "$PREFIX/.logs" || die "Cannot create $PREFIX/.logs"
  _prev_manifest="$PREFIX/.logs/_prev_manifest_$$"
  _prev_sorted="$PREFIX/.logs/_prev_sorted_$$"
  _new_sorted="$PREFIX/.logs/_new_sorted_$$"
  _orphans="$PREFIX/.logs/_orphans_$$"
  if $_priv cat "$_manifest" > "$_prev_manifest" 2>/dev/null \
     && [ -s "$_prev_manifest" ]; then
    LC_ALL=C sort -u "$_prev_manifest" > "$_prev_sorted" \
      || die "Cannot sort the previous manifest read from $_manifest"
    LC_ALL=C sort -u "$_manifest_tmp" > "$_new_sorted" \
      || die "Cannot sort the manifest accumulator at $_manifest_tmp"
    LC_ALL=C comm -23 "$_prev_sorted" "$_new_sorted" > "$_orphans" \
      || die "Cannot compare the previous manifest at $_manifest against this run"
    if [ -s "$_orphans" ]; then
      _remove_manifest_entries files "$_orphans" "$_install_prefix_real"
      # Reported only when something actually went, because _mr_removed counts
      # what was ON DISK: an orphan list whose files a user already deleted by
      # hand is a reconcile with nothing to do, and "pruned 0 file(s)" reads as
      # a failure to prune rather than as nothing to prune.
      if [ "$_mr_removed" -gt 0 ]; then
        log "  pruned $_mr_removed file(s) this build no longer ships"
      fi
      _remove_manifest_entries dirs "$_orphans" "$_install_prefix_real"
    fi
    rm -f "$_orphans" "$_new_sorted" "$_prev_sorted"
  fi
  rm -f "$_prev_manifest"

  # Finalize manifest: move the /tmp accumulator into the prefix.
  #
  # Through _place_file, not a hand-rolled `rm -f` + `cp`. The manifest needs
  # exactly the guarantees that function already provides — unlink before copy,
  # because `cp` follows a symlink at the destination and this one's path is the
  # only one an attacker can predict without knowing anything about the build;
  # a failure that is actually checked, because a manifest that was never
  # written makes `uninstall` a no-op over files that are really there; and a
  # containment check resolved at the moment of the write rather than inherited
  # from a string computed hundreds of lines earlier.
  #
  # It is NOT recorded in itself, which is why this calls _place_file rather
  # than _install_file: the manifest is the record, not an entry in it.
  #
  # _place_context replaces the copy-failure message for this one call — an
  # implicit fourth parameter, since a real one would put _place_file at four
  # positionals. _place_file consumes and clears it on entry, so it cannot
  # survive into any other call.
  #
  # The generic message names a file and a source, which is the right thing to
  # say about a header or a library; for the manifest the consequence is what
  # matters and it is specific — every file is already on disk by now, so losing
  # the record leaves a tree `uninstall` cannot touch.
  # tests/install-containment.sh pins that this failure aborts AND says so.
  if [ -f "$_manifest_tmp" ]; then
    _place_context="failed to write the manifest at $_manifest.
  The files listed in $_manifest_tmp were installed and are NOT recorded, so
  'uninstall' cannot remove them. Remove them by hand or re-run install."
    _place_file "$_manifest_tmp" "$_manifest" "$_priv"
    rm -f "$_manifest_tmp"
  fi

  _count=$(wc -l < "$_manifest" 2>/dev/null || printf '0')
  log "Installed $_count files to $_install_prefix"
}

# ─── Uninstall ───────────────────────────────────────────────────────

do_uninstall() {
  _cli_prefix="$1"

  if [ -n "$_cli_prefix" ]; then
    # Direct prefix specified
    _locations="$_cli_prefix"
  else
    # Scan known locations for manifests. Covers both the legacy "install over
    # the whole prefix" pattern (/usr/local, ~/.local) and the canonical
    # isolated-subdir pattern used to avoid shadowing system .pc files
    # (~/.local/mediaforge, ~/opt/mediaforge, /opt/mediaforge — mirroring
    # Homebrew/MacPorts/stow conventions).
    _locations=""
    for _loc in \
      /usr/local \
      /opt/mediaforge \
      "$HOME/.local" \
      "$HOME/.local/mediaforge" \
      "$HOME/opt/mediaforge"; do
      if [ -f "$_loc/.mediaforge-manifest" ]; then
        _locations="$_locations $_loc"
      fi
    done

    if [ -z "$_locations" ]; then
      die "No mediaforge installations found."
    fi

    # Count installations
    _count=0
    for _loc in $_locations; do
      _count=$((_count + 1))
    done

    if [ "$_count" -eq 1 ] && [ "$AUTOINSTALL" = "yes" ]; then
      # Only one install and --yes mode
      _locations=$(printf '%s' "$_locations" | sed 's/^ //')
    elif [ "$AUTOINSTALL" != "yes" ]; then
      printf '\n  Found mediaforge installations:\n'
      _i=0
      for _loc in $_locations; do
        _i=$((_i + 1))
        _fcount=$(wc -l < "$_loc/.mediaforge-manifest" 2>/dev/null || printf '?')
        _label="User"
        case "$_loc" in /usr|/usr/*) _label="System" ;; esac
        _sudo_hint=""
        [ ! -w "$_loc" ] && _sudo_hint=" (requires sudo)"
        printf '    %d) %-8s %s     (%s files%s)\n' "$_i" "$_label" "$_loc" "$_fcount" "$_sudo_hint"
      done
      printf '\n  Uninstall from [1-%d]: ' "$_count"
      read -r _choice

      _i=0
      _selected=""
      for _loc in $_locations; do
        _i=$((_i + 1))
        if [ "$_i" = "$_choice" ]; then
          _selected="$_loc"
          break
        fi
      done
      if [ -z "$_selected" ]; then
        die "Invalid selection"
      fi
      _locations="$_selected"
    fi
  fi

  for _target in $_locations; do
    _manifest="$_target/.mediaforge-manifest"
    if [ ! -f "$_manifest" ]; then
      warn "No manifest found at $_target -- skipping"
      continue
    fi

    _priv=""
    if _needs_priv "$_target"; then
      _priv="sudo"
    fi

    if [ "$AUTOINSTALL" != "yes" ]; then
      printf '  Uninstall from %s? [Y/n] ' "$_target"
      read -r _confirm
      case "$_confirm" in
        ""|[yY]|[yY][eE][sS]) ;;
        *) log "Skipped."; continue ;;
      esac
    fi

    # Resolved under $_priv, like do_install resolves its own prefix: the
    # removals run under that privilege, so the containment boundary has to be
    # the one they will see. This also normalises a trailing slash on --prefix,
    # which `pwd -P` never emits — without it the rmdir climb below compares
    # "<prefix>//lib" against "<prefix>/" and never reaches its terminator.
    _target_real=$(_resolve_existing "$_target" "$_priv")
    if [ -z "$_target_real" ]; then
      warn "Cannot resolve $_target -- skipping"
      continue
    fi
    # Rebound onto the RESOLVED prefix now that we have it. The discovery check
    # above had to use $_target — it runs before anything is resolved, and its
    # job is only "is there a manifest here at all". Every privileged use of the
    # path below wants the boundary, not the string the user typed.
    _manifest="$_target_real/.mediaforge-manifest"

    _remove_manifest_entries files "$_manifest" "$_target_real"
    _removed="$_mr_removed"

    # Sweep dangling symlinks under mediaforge's known install subtrees only.
    # User-created shim dirs (e.g. lib/pkgconfig-ffmpeg/) commonly contain
    # symlinks pointing back to lib/pkgconfig/ files that the manifest just
    # removed; those become broken and we tidy them. Restricting the scope to
    # bin/lib/include/share/man avoids touching unrelated user trees like
    # share/pnpm or share/applications.
    #
    # Enumeration and deletion both happen inside lib/remove-listed-files.sh,
    # like every other privileged delete here. This used to be a `find | while`
    # loop running `$_priv rm -f "$_link"` on a composed path it had never
    # entered — a check-then-act gap, and the last place not following the rule
    # the helper exists to enforce. Being the only exception is how a rule stops
    # being one. Moving the `find` inside also fixes a defect the loop carried:
    # it ran UNPRIVILEGED, so on a root-owned prefix it enumerated a tree it
    # could not read and swept nothing.
    # Staged in /tmp, NOT $PREFIX/.logs. The .logs precedent belongs to the
    # INSTALL path, whose justification is "$PREFIX is the tree we just built as
    # this user" — uninstall has no such claim on it. PREFIX is set
    # unconditionally by mediaforge.sh and uninstall needs nothing else from it,
    # so writing there would have `uninstall` create a build workspace as a side
    # effect, in a fresh clone or after `clean`. Same reasoning, and the same
    # mktemp O_EXCL, as the manifest accumulator.
    #
    # A `die`, not a skip: with the list unwritable the sweeps are silently
    # halved and the manifest is deleted immediately after, leaving a partial
    # removal with no record of what is left. That is the failure this whole
    # branch exists to stop reporting as success.
    _sweep_roots=$(mktemp /tmp/mediaforge-sweep-roots.XXXXXX) \
      || die "Cannot create the sweep root list in /tmp"
    printf '%s\n' bin lib include share/man > "$_sweep_roots" \
      || die "Cannot write the sweep root list at $_sweep_roots"
    _remove_manifest_entries links "$_sweep_roots" "$_target_real"

    # Clean up empty directories left behind (bottom-up). This overwrites
    # _mr_removed with a DIRECTORY count, which is why _removed was taken above;
    # the count is deliberately not reported, because "removed N files" is what
    # an operator is checking and a second number beside it invites the two to be
    # read as one total.
    _remove_manifest_entries dirs "$_manifest" "$_target_real"

    # Second rmdir pass: clean directories left empty by the dangling-symlink
    # sweep. Includes the top-level $_target/{bin,lib,include,share/man,share}
    # subdirs themselves — `rmdir` refuses non-empty dirs, so shared prefixes
    # like /usr/local where other packages live in those subdirs are
    # naturally protected. Only mediaforge-exclusive subdirs vanish.
    #
    # Same helper, same rule, for the same reasons as the sweep above. The
    # 'emptydirs' mode additionally repeats to a FIXPOINT, which the `find
    # -depth` loop it replaces did not: find decides -empty when it visits a
    # directory, so a parent that empties only once its last child is removed
    # was left behind.
    #
    # That widens the reach, so say it plainly: the pass now removes nested
    # empties all the way up, which is what the paragraph above always promised
    # and the single pass only half-delivered. On a SHARED prefix that means an
    # already-empty /usr/local/share we did not create is now removed where the
    # old code left it. `rmdir` on an empty directory is about as harmless as a
    # removal gets, and it is the documented intent — but it IS a behaviour
    # change, and the next reader should not have to diff to find it.
    printf '%s\n' bin lib include share/man share > "$_sweep_roots" \
      || die "Cannot write the sweep root list at $_sweep_roots"
    _remove_manifest_entries emptydirs "$_sweep_roots" "$_target_real"

    # Through the same helper as every other delete, rather than a `$_priv rm -f`
    # on a composed path. Reusing the roots list rather than staging a third
    # temp: it has served both sweeps and is about to be removed anyway.
    #
    # The earlier version of this argued that a DIRECT CHILD of the prefix needs
    # no containment because the only component between the boundary and the
    # leaf is the boundary itself. True — but only of the RESOLVED boundary, and
    # only if it is re-checked at the moment of the delete rather than inherited
    # from a string resolved earlier in the run. Both conditions are easier to
    # satisfy by using the helper than to argue about in a comment.
    printf '%s\n' .mediaforge-manifest > "$_sweep_roots" \
      || die "Cannot write the manifest removal list at $_sweep_roots"
    _remove_manifest_entries files "$_sweep_roots" "$_target_real"
    rm -f "$_sweep_roots"

    # Finally, attempt to remove the prefix root itself. This succeeds only
    # when the prefix was mediaforge-exclusive (e.g. ~/.local/mediaforge,
    # /opt/mediaforge) and is now empty. Shared prefixes (~/.local,
    # /usr/local) keep other packages' files and the rmdir naturally fails —
    # no harm done. Net effect: full pristine revert for isolated prefixes,
    # conservative for shared ones.
    #
    # Also not routed through the helper, and safe for a second reason: `rmdir`
    # does not follow a symlink at the final component, so a prefix swapped for
    # one fails with ENOTDIR rather than removing the link's target. Named by
    # its resolved path for the same reason as the manifest above.
    $_priv rmdir "$_target_real" 2>/dev/null && log "Removed empty prefix $_target"

    log "Removed $_removed files from $_target"
  done
}
