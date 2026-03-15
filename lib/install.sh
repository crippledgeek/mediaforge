#!/bin/sh
# Install ffmpeg binaries to system

# Determine install location
INSTALL_FOLDER="/usr"
if [ "$IS_DARWIN" = true ]; then
  INSTALL_FOLDER="/usr/local"
elif [ -d "$HOME/.local" ]; then
  INSTALL_FOLDER="$HOME/.local"
elif [ -d "/usr/local" ]; then
  INSTALL_FOLDER="/usr/local"
fi

# Decide whether to install
INSTALL_NOW=0
if [ "$AUTOINSTALL" = "yes" ]; then
  INSTALL_NOW=1
  log "Auto-installing binaries (--auto-install)."
elif [ "$SKIPINSTALL" = "yes" ]; then
  log "Skipping install (--skip-install)."
else
  printf '[mediaforge] Install binaries to %s? Existing binaries will be replaced. [Y/n] ' "$INSTALL_FOLDER"
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
  case "$INSTALL_FOLDER" in
    /usr|/usr/*)
      if command_exists "sudo"; then
        SUDO=sudo
      fi
      ;;
  esac

  $SUDO cp "$WORKSPACE/bin/ffmpeg" "$INSTALL_FOLDER/bin/ffmpeg"
  $SUDO cp "$WORKSPACE/bin/ffprobe" "$INSTALL_FOLDER/bin/ffprobe"
  $SUDO cp "$WORKSPACE/bin/ffplay" "$INSTALL_FOLDER/bin/ffplay"

  if [ "$MANPAGES" = 1 ]; then
    $SUDO mkdir -p "$INSTALL_FOLDER/share/man/man1"
    $SUDO cp "$WORKSPACE/share/man/man1"/ff* "$INSTALL_FOLDER/share/man/man1/"
    if command_exists "mandb"; then
      $SUDO mandb -q
    fi
  fi

  log "FFmpeg installed to $INSTALL_FOLDER"
fi
