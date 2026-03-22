#!/bin/sh
# Download and extract helpers

# fetch [URL [FILENAME [DIRNAME]]]
# Reads PKG_URL, PKG_FILENAME, PKG_DIRNAME by default.
# Positional args override for non-recipe downloads (ffmpeg.sh, sub-packages).
fetch() {
  _url="${1:-$PKG_URL}"
  _file="${2:-${PKG_FILENAME:-${_url##*/}}}"
  _dir="${3:-$PKG_DIRNAME}"

  # Auto-detect target dir from tarball name if not specified
  if [ -z "$_dir" ]; then
    case "$_file" in
      *.tar.gz)  _dir="${_file%.tar.gz}" ;;
      *.tar.xz)  _dir="${_file%.tar.xz}" ;;
      *.tar.bz2) _dir="${_file%.tar.bz2}" ;;
      *.zip)     _dir="${_file%.zip}" ;;
      *)         _dir="${_file%.*}" ;;
    esac
  fi

  # Download if not cached
  if [ ! -f "$DISTDIR/$_file" ]; then
    log "Downloading $_url"
    _retry_wait=1
    _ok=false
    _attempts=0
    while [ "$_attempts" -lt 3 ]; do
      if curl -L -sS -o "$DISTDIR/$_file" "$_url"; then
        _ok=true
        break
      fi
      rm -f "$DISTDIR/$_file"
      _attempts=$((_attempts + 1))
      if [ "$_attempts" -lt 3 ]; then
        warn "Download failed. Retrying in ${_retry_wait}s..."
        sleep "$_retry_wait"
        _retry_wait=$((_retry_wait * 2))
      fi
    done
    if [ "$_ok" != true ]; then
      die "Failed to download $_url after 3 attempts"
    fi
    log "Download complete"
  else
    log "$_file already cached"
  fi

  # Skip extraction for patch files
  case "$_file" in
    *patch*) return 0 ;;
  esac

  # Extract based on archive type
  rm -rf "$DISTDIR/$_dir"
  mkdir -p "$DISTDIR/$_dir" || die "Failed to create $DISTDIR/$_dir"

  if [ -n "$3" ]; then
    _strip=""
  else
    _strip="--strip-components 1"
  fi

  case "$_file" in
    *.tar.gz|*.tgz)
      # shellcheck disable=SC2086
      tar -xzf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.tar.xz)
      # shellcheck disable=SC2086
      tar -xJf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.tar.bz2)
      # shellcheck disable=SC2086
      tar -xjf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.zip)
      unzip -q -o "$DISTDIR/$_file" -d "$DISTDIR/$_dir" 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *)
      # Fallback: let tar auto-detect
      # shellcheck disable=SC2086
      tar -xf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
  esac

  log "Extracted $_file"
  cd "$DISTDIR/$_dir" || die "Failed to enter $DISTDIR/$_dir"
}
