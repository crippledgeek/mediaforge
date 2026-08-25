#!/bin/sh
# Install/uninstall mediaforge-built FFmpeg binaries and libraries.
#
# Install layer is intentionally dumb: it copies whatever is in the
# workspace pkgconfig dir at install time. Transitive-utility .pc files
# (fontconfig, harfbuzz, freetype2, ...) are removed from the workspace
# by recipes/ffmpeg.sh's post-build hook, which processes the queue
# populated by recipes that declared PKG_TRANSITIVE_UTIL=true. Decision
# of "should this .pc be installed?" lives in the recipe layer where the
# recipe author knows the intent — no central distro-flavored stop-list.

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

# Copy a file, creating parent dirs as needed. Appends the installed-relative
# path to the manifest accumulator at $_manifest_tmp_path.
#
# The accumulator lives in /tmp (user-writable regardless of $_install_prefix
# ownership). Without this split, root-owned prefixes silently corrupt the
# manifest because the >> redirection here is plain shell I/O, NOT gated by
# $_priv. /tmp keeps the accumulator outside any sudo concern.
#
# Reads $_install_prefix_real, which do_install resolves once after creating the
# prefix: it is the containment BOUNDARY, it cannot change mid-install, and
# resolving it per file would put back an exec the helper below exists to avoid.
# Each DESTINATION is still resolved per file, inside that helper.
_install_file() {
  _src="$1"
  _dest="$2"
  _manifest_tmp_path="$3"
  _priv="$4"

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
    _install_helper=$(cat "$SCRIPT_DIR/lib/install-one-file.sh") \
      || die "Cannot read the install helper at $SCRIPT_DIR/lib/install-one-file.sh"
    # An empty read is a truncated or missing helper. Caught here rather than
    # later, because an empty script exits 0 under POSIX and every install would
    # report success having copied nothing.
    [ -n "$_install_helper" ] \
      || die "The install helper at $SCRIPT_DIR/lib/install-one-file.sh is empty."
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
  completing — no INSTALLED sentinel. The helper text may be truncated or
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
    3) die "cannot resolve the install destination '$_dest' — refusing to write." ;;
    5) die "failed to install $_dest (source: $_src).
  Nothing is at that path now — the previous file, if any, was removed before
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
  mkdir/cp/rm will refuse — that is one cause. A missing or unreadable helper is
  the other.
  A root install needs no per-file elevation at all and is the way past a
  policy like that: re-run the whole command as root — from a root shell, or
  through a sudoers entry for this script, since a policy that refuses sh
  refuses 'sudo ./mediaforge.sh' just as readily. For example
  'sudo ./mediaforge.sh install --prefix=$_install_prefix'. Do that only for a
  SYSTEM prefix: as root into a user-owned one it leaves root-owned files
  behind. Scoping an entry to the helper instead is not available — it reaches
  sh as text, not as a path, so there is no command name to name." ;;
    *) die "internal: the install helper for '$_dest' exited $_install_rc" ;;
  esac

  printf '%s\n' "${_dest#"$_install_prefix"/}" >> "$_manifest_tmp_path"
}

# ─── Prefix Selection ────────────────────────────────────────────────

# Present interactive menu or use provided prefix
# Sets _install_prefix and _priv
_select_prefix() {
  _install_prefix=""
  _priv=""

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

# ─── Install ─────────────────────────────────────────────────────────

do_install() {
  _cli_prefix="$1"

  _select_prefix

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

  _manifest="$_install_prefix/.mediaforge-manifest"
  # Manifest accumulator lives in /tmp so unprivileged appends always work,
  # even when $_install_prefix is root-owned. mktemp uses O_EXCL — closes the
  # PID-predictable symlink-race window of a bare `/tmp/<name>.$$`.
  # Finalised via $_priv cp at end.
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

  # pkgconfig files (rewrite prefix). The workspace pkgconfig dir was
  # already curated by recipes/ffmpeg.sh — transitive-util .pc files were
  # removed there per each recipe's PKG_TRANSITIVE_UTIL declaration.
  # Install layer is dumb: copy whatever survived.
  for _pc in "$PREFIX/lib/pkgconfig/"*.pc; do
    [ -f "$_pc" ] || continue
    _name=$(basename "$_pc")
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
  # Parsed with sed rather than sourced. load_stored_choices sources it, but
  # this function runs privileged commands, and sourcing build output into a
  # process that shells out under sudo is a worse trust posture than parsing a
  # value out of it.
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

  # Finalize manifest: move /tmp accumulator into the prefix (privileged if needed)
  #
  # Not routed through _install_file — the source is in /tmp and the manifest is
  # not itself a manifested file — so the two guards that function carries have
  # to be repeated here, and only here:
  #
  #  * unlink first, because `cp` follows a symlink at the destination. A
  #    symlink planted at <prefix>/.mediaforge-manifest redirects this write,
  #    which runs under $_priv, to an attacker-chosen file. The manifest is the
  #    one destination whose path an attacker can predict without knowing
  #    anything about the build.
  #  * check the copy, because a manifest that was never written makes
  #    `uninstall` a no-op over files that are really there — the install
  #    reports success and leaves an untracked tree behind.
  #
  # Containment needs no repeat: the destination is $_install_prefix itself,
  # which _install_prefix_real resolved and the die above already vetted.
  if [ -f "$_manifest_tmp" ]; then
    $_priv rm -f "$_manifest" 2>/dev/null
    $_priv cp "$_manifest_tmp" "$_manifest" \
      || die "failed to write the manifest at $_manifest.
  The files listed in $_manifest_tmp were installed and are NOT recorded, so
  'uninstall' cannot remove them. Remove them by hand or re-run install."
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
      warn "No manifest found at $_target — skipping"
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

    _removed=0
    while IFS= read -r _rel; do
      [ -z "$_rel" ] && continue
      # Reject manifest entries that could traverse out of $_target. A
      # tampered manifest (or compromised install) could otherwise drive
      # `$_priv rm -f` against arbitrary paths under sudo.
      case "$_rel" in
        /*|*/../*|../*|..)
          warn "Suspicious manifest entry skipped: $_rel"
          continue ;;
      esac
      _file="$_target/$_rel"
      if [ -f "$_file" ]; then
        $_priv rm -f "$_file"
        _removed=$((_removed + 1))
      fi
    done < "$_manifest"

    # Sweep dangling symlinks under mediaforge's known install subtrees only.
    # User-created shim dirs (e.g. lib/pkgconfig-ffmpeg/) commonly contain
    # symlinks pointing back to lib/pkgconfig/ files that the manifest just
    # removed; those become broken and we tidy them. Restricting the scope to
    # bin/lib/include/share/man avoids touching unrelated user trees like
    # share/pnpm or share/applications.
    for _sweep in bin lib include share/man; do
      [ -d "$_target/$_sweep" ] || continue
      find "$_target/$_sweep" -type l 2>/dev/null | while IFS= read -r _link; do
        if [ ! -e "$_link" ]; then
          $_priv rm -f "$_link"
        fi
      done
    done

    # Clean up empty directories left behind (bottom-up)
    # Sort deepest paths first so rmdir works bottom-up
    while IFS= read -r _rel; do
      [ -z "$_rel" ] && continue
      _dir="$_target/$(dirname "$_rel")"
      while [ "$_dir" != "$_target" ] && [ -d "$_dir" ]; do
        $_priv rmdir "$_dir" 2>/dev/null || break
        _dir=$(dirname "$_dir")
      done
    done < "$_manifest"

    # Second rmdir pass: clean directories left empty by the dangling-symlink
    # sweep. Includes the top-level $_target/{bin,lib,include,share/man,share}
    # subdirs themselves — `rmdir` refuses non-empty dirs, so shared prefixes
    # like /usr/local where other packages live in those subdirs are
    # naturally protected. Only mediaforge-exclusive subdirs vanish.
    for _sub in bin lib include share/man share; do
      [ -d "$_target/$_sub" ] || continue
      find "$_target/$_sub" -depth -type d -empty 2>/dev/null \
        | while IFS= read -r _empty; do
            $_priv rmdir "$_empty" 2>/dev/null || true
          done
    done

    $_priv rm -f "$_manifest"

    # Finally, attempt to remove the prefix root itself. This succeeds only
    # when the prefix was mediaforge-exclusive (e.g. ~/.local/mediaforge,
    # /opt/mediaforge) and is now empty. Shared prefixes (~/.local,
    # /usr/local) keep other packages' files and the rmdir naturally fails —
    # no harm done. Net effect: full pristine revert for isolated prefixes,
    # conservative for shared ones.
    $_priv rmdir "$_target" 2>/dev/null && log "Removed empty prefix $_target"

    log "Removed $_removed files from $_target"
  done
}
