#!/bin/sh
# Install/uninstall mediaforge-built FFmpeg binaries and libraries

# ─── Helpers ──────────────────────────────────────────────────────────

# Detect if we need privilege escalation for a target directory
_needs_priv() {
  [ ! -w "$1" ] && command_exists "sudo"
}

# Copy a file, creating parent dirs as needed. Appends to manifest.
_install_file() {
  _src="$1"
  _dest="$2"
  _manifest="$3"
  _priv="$4"

  $_priv mkdir -p "$(dirname "$_dest")" 2>/dev/null
  $_priv cp "$_src" "$_dest"
  # Write relative path to manifest
  printf '%s\n' "${_dest#"$_install_prefix"/}" >> "$_manifest.tmp"
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

  _manifest="$_install_prefix/.mediaforge-manifest"
  rm -f "$_manifest.tmp" 2>/dev/null

  # Binaries
  for _bin in ffmpeg ffprobe ffplay; do
    if [ -f "$PREFIX/bin/$_bin" ]; then
      _install_file "$PREFIX/bin/$_bin" "$_install_prefix/bin/$_bin" "$_manifest" "$_priv"
      $_priv chmod 755 "$_install_prefix/bin/$_bin"
      log "  bin/$_bin"
    fi
  done

  # Static libraries
  for _lib in "$PREFIX/lib/"*.a; do
    [ -f "$_lib" ] || continue
    _name=$(basename "$_lib")
    _install_file "$_lib" "$_install_prefix/lib/$_name" "$_manifest" "$_priv"
    log "  lib/$_name"
  done

  # pkgconfig files (rewrite prefix)
  for _pc in "$PREFIX/lib/pkgconfig/"*.pc; do
    [ -f "$_pc" ] || continue
    _name=$(basename "$_pc")
    _tmppc="$PREFIX/.logs/_pc_rewrite_$$"
    awk -v old="$PREFIX" -v new="$_install_prefix" '{gsub(old, new)} {print}' "$_pc" > "$_tmppc"
    _install_file "$_tmppc" "$_install_prefix/lib/pkgconfig/$_name" "$_manifest" "$_priv"
    rm -f "$_tmppc"
    log "  lib/pkgconfig/$_name"
  done

  # Headers
  if [ -d "$PREFIX/include" ]; then
    (cd "$PREFIX/include" && find . -type f) | while IFS= read -r _hdr; do
      _hdr="${_hdr#./}"
      _install_file "$PREFIX/include/$_hdr" "$_install_prefix/include/$_hdr" "$_manifest" "$_priv"
    done
    log "  include/ (headers)"
  fi

  # Man pages
  if [ "$INSTALL_MANPAGES" = 1 ] && [ -d "$PREFIX/share/man/man1" ]; then
    for _man in "$PREFIX/share/man/man1"/ff*; do
      [ -f "$_man" ] || continue
      _name=$(basename "$_man")
      _install_file "$_man" "$_install_prefix/share/man/man1/$_name" "$_manifest" "$_priv"
    done
    if command_exists "mandb"; then
      $_priv mandb -q 2>/dev/null
    fi
    log "  share/man/man1/ (man pages)"
  fi

  # Finalize manifest
  if [ -f "$_manifest.tmp" ]; then
    $_priv cp "$_manifest.tmp" "$_manifest"
    rm -f "$_manifest.tmp"
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
    # Scan known locations for manifests
    _locations=""
    for _loc in /usr/local "$HOME/.local"; do
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
    # sweep. Same bounded scope as the sweep above.
    for _sub in bin lib include share/man; do
      [ -d "$_target/$_sub" ] || continue
      find "$_target/$_sub" -depth -type d -empty 2>/dev/null \
        | while IFS= read -r _empty; do
            [ "$_empty" = "$_target/$_sub" ] && continue
            $_priv rmdir "$_empty" 2>/dev/null || true
          done
    done

    $_priv rm -f "$_manifest"
    log "Removed $_removed files from $_target"
  done
}
