#!/bin/sh
# Final FFmpeg build — consumes FFMPEG_CONFIGURE_OPTS from all recipes

# flite links against ALSA on Linux (static libflite.a references snd_pcm_*)
if [ "$OS_LINUX" = true ] && [ -f "$PREFIX/lib/libflite.a" ]; then
  EXTRALIBS="$EXTRALIBS -lasound"
fi

EXTRA_VERSION=""
if [ "$OS_MACOS" = true ]; then
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
if [ -n "$NVCCFLAGS" ]; then
  _nvcc_opt="$NVCCFLAGS"
fi

# Prevent ffmpeg's version.sh from detecting the project's .git
# shellcheck disable=SC2086
GIT_DIR=/nonexistent \
execute ./configure $FFMPEG_CONFIGURE_OPTS \
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
  --pkgconfigdir="$PREFIX/lib/pkgconfig" \
  --pkg-config-flags="--static" \
  --prefix="$PREFIX" \
  --extra-version="$EXTRA_VERSION"

execute make -j "$MJOBS"
execute make install

# Verify the binary
if command_exists "file"; then
  _binary_type=$(file "$PREFIX/bin/ffmpeg" | sed 's/^.*: //')
  log ""
  log "Built binary: $_binary_type"
fi

log ""
log "Build complete. Binaries available at:"
log "  ffmpeg:  $PREFIX/bin/ffmpeg"
log "  ffprobe: $PREFIX/bin/ffprobe"
log "  ffplay:  $PREFIX/bin/ffplay"
