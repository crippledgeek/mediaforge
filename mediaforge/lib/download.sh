#!/bin/sh
# Download and extract helpers

# download URL [FILENAME [DIRNAME]]
download() {
  _url="$1"
  _file="${2:-${_url##*/}}"
  _dir="$3"

  # Auto-detect target dir from tarball name if not specified
  if [ -z "$_dir" ]; then
    case "$_file" in
      *.tar.gz)  _dir="${_file%.tar.gz}" ;;
      *.tar.xz)  _dir="${_file%.tar.xz}" ;;
      *.tar.bz2) _dir="${_file%.tar.bz2}" ;;
      *)         _dir="${_file%.*}" ;;
    esac
  fi

  # Download if not cached
  if [ ! -f "$DISTDIR/$_file" ]; then
    log "Downloading $_url"
    if ! curl -L -sS -o "$DISTDIR/$_file" "$_url"; then
      rm -f "$DISTDIR/$_file"
      warn "Download failed. Retrying in 10 seconds..."
      sleep 10
      if ! curl -L -sS -o "$DISTDIR/$_file" "$_url"; then
        rm -f "$DISTDIR/$_file"
        die "Failed to download $_url"
      fi
    fi
    log "Download complete"
  else
    log "$_file already cached"
  fi

  # Skip extraction for patch files
  case "$_file" in
    *patch*) return 0 ;;
  esac

  # Extract
  remove_dir "$DISTDIR/$_dir"
  mkdir -p "$DISTDIR/$_dir" || die "Failed to create $DISTDIR/$_dir"

  if [ -n "$3" ]; then
    _strip=""
  else
    _strip="--strip-components 1"
  fi

  # shellcheck disable=SC2086
  if ! tar -xf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null; then
    die "Failed to extract $_file"
  fi

  log "Extracted $_file"
  cd "$DISTDIR/$_dir" || die "Failed to enter $DISTDIR/$_dir"
}
