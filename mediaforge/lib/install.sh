#!/bin/sh
# Install ffmpeg binaries to system

# Determine install location
DESTDIR="/usr"
if [ "$OS_MACOS" = true ]; then
  DESTDIR="/usr/local"
elif [ -d "$HOME/.local" ]; then
  DESTDIR="$HOME/.local"
elif [ -d "/usr/local" ]; then
  DESTDIR="/usr/local"
fi

# Decide whether to install
INSTALL_NOW=0
if [ "$AUTOINSTALL" = "yes" ]; then
  INSTALL_NOW=1
  log "Auto-installing binaries (--auto-install)."
elif [ "$SKIP_INSTALL" = "yes" ]; then
  log "Skipping install (--skip-install)."
else
  printf '[mediaforge] Install binaries to %s? Existing binaries will be replaced. [Y/n] ' "$DESTDIR"
  read -r response
  case "$response" in
    ""|[yY]|[yY][eE][sS])
      INSTALL_NOW=1
      ;;
  esac
fi

if [ "$INSTALL_NOW" = 1 ]; then
  # Determine if we need sudo
  SUDO=""
  case "$DESTDIR" in
    /usr|/usr/*)
      if command_exists "sudo"; then
        SUDO=sudo
      fi
      ;;
  esac

  $SUDO cp "$PREFIX/bin/ffmpeg" "$DESTDIR/bin/ffmpeg"
  $SUDO cp "$PREFIX/bin/ffprobe" "$DESTDIR/bin/ffprobe"
  $SUDO cp "$PREFIX/bin/ffplay" "$DESTDIR/bin/ffplay"

  if [ "$INSTALL_MANPAGES" = 1 ]; then
    $SUDO mkdir -p "$DESTDIR/share/man/man1"
    $SUDO cp "$PREFIX/share/man/man1"/ff* "$DESTDIR/share/man/man1/"
    if command_exists "mandb"; then
      $SUDO mandb -q
    fi
  fi

  log "FFmpeg installed to $DESTDIR"
fi
