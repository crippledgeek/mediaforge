#!/bin/sh
# Final FFmpeg build — consumes CONFIGURE_OPTIONS from all recipes

EXTRA_VERSION=""
if [ "$IS_DARWIN" = true ]; then
  EXTRA_VERSION="$FFMPEG_VERSION"
fi

log ""
log "Building FFmpeg $FFMPEG_VERSION"
log "======================="

download "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
  "FFmpeg-release-${FFMPEG_VERSION}.tar.gz"

print_flags

# Handle NVIDIA flags separately (may contain spaces)
_nvcc_opt=""
if [ -n "$NVCC_FLAGS" ]; then
  _nvcc_opt="$NVCC_FLAGS"
fi

# Prevent ffmpeg's version.sh from detecting the project's .git
# shellcheck disable=SC2086
GIT_DIR=/nonexistent \
execute ./configure $CONFIGURE_OPTIONS \
  $_nvcc_opt \
  --disable-debug \
  --disable-shared \
  --enable-pthreads \
  --enable-static \
  --enable-version3 \
  --extra-cflags="$CFLAGS" \
  --extra-ldexeflags="$LDEXEFLAGS" \
  --extra-ldflags="$LDFLAGS" \
  --extra-libs="$EXTRALIBS" \
  --pkgconfigdir="$WORKSPACE/lib/pkgconfig" \
  --pkg-config-flags="--static" \
  --prefix="$WORKSPACE" \
  --extra-version="$EXTRA_VERSION"

execute make -j "$MJOBS"
execute make install

# Verify the binary
if command_exists "file"; then
  _binary_type=$(file "$WORKSPACE/bin/ffmpeg" | sed 's/^.*: //')
  log ""
  log "Built binary: $_binary_type"
fi

log ""
log "Build complete. Binaries available at:"
log "  ffmpeg:  $WORKSPACE/bin/ffmpeg"
log "  ffprobe: $WORKSPACE/bin/ffprobe"
log "  ffplay:  $WORKSPACE/bin/ffplay"
