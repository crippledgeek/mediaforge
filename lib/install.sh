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

# Detect if we need privilege escalation to install into $1.
#
# POSIX `test -w` returns false on nonexistent paths, so a naive
# `[ ! -w "$target" ]` always elevates for fresh prefixes whose parent the
# user owns. Canonical fix: walk up to the first existing ancestor and
# check ITS writability — that answers "can the current process create
# this tree?" rather than "does this path already exist and is it writable?".
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

  _np_ancestor="$_np_target"
  while [ ! -d "$_np_ancestor" ]; do
    _np_ancestor=$(dirname "$_np_ancestor")
  done

  if [ -w "$_np_ancestor" ]; then
    return 1
  fi

  if ! command_exists sudo; then
    die "Cannot write to '$_np_target' and sudo is not available. " \
        "Re-run as root or choose a user-writable prefix."
  fi
  return 0
}

# Resolve a path to its PHYSICAL location by walking to the nearest EXISTING
# ancestor and resolving that. `cd`/`pwd -P` only answer for paths that exist,
# and install destinations frequently do not yet.
#
# Prints nothing (and returns non-zero) when nothing in the chain resolves, so
# callers must treat an empty result as "unknown", never as "matches".
_resolve_existing() {
  _re_path="$1"
  while [ ! -d "$_re_path" ] && [ "$_re_path" != "/" ]; do
    _re_path=$(dirname "$_re_path")
  done
  (cd "$_re_path" 2>/dev/null && pwd -P)
}

# Copy a file, creating parent dirs as needed. Appends the installed-relative
# path to the manifest accumulator at $_manifest_tmp_path.
#
# The accumulator lives in /tmp (user-writable regardless of $_install_prefix
# ownership). Without this split, root-owned prefixes silently corrupt the
# manifest because the >> redirection here is plain shell I/O, NOT gated by
# $_priv. /tmp keeps the accumulator outside any sudo concern.
_install_file() {
  _src="$1"
  _dest="$2"
  _manifest_tmp_path="$3"
  _priv="$4"

  $_priv mkdir -p "$(dirname "$_dest")" 2>/dev/null
  # Unlink first: `cp` FOLLOWS a symlink at the destination and overwrites what
  # it points at, leaving the link itself in place. A symlink pre-planted at any
  # destination path — planted while the prefix was writable, no race required —
  # would otherwise redirect this copy, which runs under $_priv (sudo for a
  # system prefix), into an arbitrary file: an attacker-chosen destination for a
  # privileged write. `rm -f` removes the LINK without following it.
  #
  # Here rather than at one call site: every caller (binaries, static libs,
  # pkgconfig, headers, man pages, the CA bundle) shares the same exposure, and
  # a guard that protects only the newest destination invites the next one to
  # miss it. POSIX cp has no portable --no-dereference-on-write, so unlink-first
  # is the idiom.
  # Belt-and-braces against the irreversible path: _select_prefix already
  # refuses an install prefix that resolves to the build prefix, which is the
  # guard that catches aliases. This one costs a line.
  [ "$_src" = "$_dest" ] && return 0

  $_priv rm -f "$_dest" 2>/dev/null
  # Checked, and checked HERE rather than left to the caller, because the unlink
  # above changed the failure mode: before it, a failed copy left the previous
  # file in place, so an unnoticed failure was survivable. Now it leaves NOTHING
  # at the destination — for the CA bundle that is a prefix with no trust store
  # at the path the binary was built to read.
  #
  # The manifest append moved below the check for the same reason: recording a
  # file that was never written makes `uninstall` report a removal count it did
  # not perform, and hides the failure a second time.
  $_priv cp "$_src" "$_dest" \
    || die "failed to install $_dest (source: $_src).
  Nothing is at that path now — the previous file, if any, was removed before
  the copy. Re-run install once the cause is fixed."
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
    _stored_tls=$(sed -n 's/^STORED_TLS_BACKEND=//p' "$PREFIX/.mediaforge-choices")
    # save_stored_choices single-quotes this one; strip the quotes.
    _stored_od=$(sed -n "s/^STORED_OPENSSLDIR='\(.*\)'$/\1/p" "$PREFIX/.mediaforge-choices")
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
      # Validate BEFORE creating anything, and validate the nearest EXISTING
      # ancestor rather than the leaf.
      #
      # The case patterns above are lexical: '..' is rejected at validation, but
      # a SYMLINK is invisible to a string match and need not exist when
      # --openssldir is validated. `mkdir -p` follows symlink components, so
      # running it first — under $_priv, i.e. sudo for a system prefix — creates
      # root-owned directories at the escaped target before any check can refuse
      # the copy. No file content escapes, but the directories do, and nothing
      # manifests them so `uninstall` cannot sweep them either.
      #
      # Walking to the nearest existing ancestor is the same technique
      # _needs_priv already uses above, and for the same reason: `test`/`cd`
      # answer questions about paths that exist, so resolve what is there and
      # let mkdir create only the symlink-free remainder.
      #
      # `cd ... && pwd -P` rather than `readlink -f`: -f is a GNU extension that
      # macOS's readlink has historically lacked, and this must work on both.
      _ca_real=$(_resolve_existing "$(dirname "$_ca_dest")")
      _prefix_real=$(_resolve_existing "$_install_prefix")
      if [ -z "$_ca_real" ] || [ -z "$_prefix_real" ]; then
        die "cannot resolve the CA bundle destination '$_ca_dest' — refusing to write."
      fi
      case "$_ca_real/" in
        "$_prefix_real"/*) : ;;
        *) die "CA bundle destination '$_ca_dest' resolves to '$_ca_real', outside
  the install prefix '$_prefix_real'. Refusing a privileged write through a
  symlink. Check for a symlinked component under the prefix." ;;
      esac
      _install_file "$PREFIX/etc/ssl/cert.pem" "$_ca_dest" "$_manifest_tmp" "$_priv"
      log "  ${_ca_dest#"$_install_prefix"/} (CA bundle)"
    fi
  fi

  # Headers
  if [ -d "$PREFIX/include" ]; then
    (cd "$PREFIX/include" && find . -type f) | while IFS= read -r _hdr; do
      _hdr="${_hdr#./}"
      _install_file "$PREFIX/include/$_hdr" "$_install_prefix/include/$_hdr" "$_manifest_tmp" "$_priv"
    done
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
  if [ -f "$_manifest_tmp" ]; then
    $_priv cp "$_manifest_tmp" "$_manifest"
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
