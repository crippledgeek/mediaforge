#!/bin/sh
# Final FFmpeg build — consumes FFMPEG_CONFIGURE_OPTS from all recipes

# If flite was built with an audio backend, FFmpeg's static link needs the
# matching system library on the link line. Default --flite-audio=none skips
# this entirely (no au_*.o in libflite.a → no unresolved symbols).
if [ "$OS_LINUX" = true ] && [ -f "$PREFIX/lib/libflite.a" ]; then
  case "$FLITE_AUDIO" in
    alsa)        EXTRALIBS="$EXTRALIBS -lasound" ;;
    pulseaudio)  EXTRALIBS="$EXTRALIBS -lpulse-simple -lpulse" ;;
    oss)         ;; # OSS uses kernel ioctl, no -l flag
    sun)         ;; # Sun audio is in libc on Solaris-likes
    none)        ;;
  esac
fi

EXTRA_VERSION="mediaforge"

log ""
log "Building FFmpeg $FFMPEG_VERSION"
log "======================="

fetch "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
  "FFmpeg-release-${FFMPEG_VERSION}.tar.gz"

print_flags

# Build the full configure command as a string, then eval it.
# This is necessary because FFMPEG_CONFIGURE_OPTS and NVCCFLAGS
# contain multiple flags that must word-split, while --extra-cflags
# and similar must preserve their quoted values.
_ffconf="./configure $FFMPEG_CONFIGURE_OPTS"

if [ -n "$NVCCFLAGS" ]; then
  _ffconf="$_ffconf --nvccflags=\"$NVCCFLAGS\""
fi

_ffconf="$_ffconf \
  --disable-debug \
  --disable-shared \
  --enable-pthreads \
  --enable-static \
  --enable-version3 \
  --extra-cflags=\"$CFLAGS\" \
  --extra-ldexeflags=\"$LDEXEFLAGS\" \
  --extra-ldflags=\"$LDFLAGS\" \
  --extra-libs=\"$EXTRALIBS\" \
  --pkgconfigdir=\"$PREFIX/lib/pkgconfig\" \
  --pkg-config-flags=\"--static\" \
  --prefix=\"$PREFIX\" \
  --extra-version=\"$EXTRA_VERSION\""

# Prevent ffmpeg's version.sh from detecting the project's .git
log "$ $_ffconf"
GIT_DIR=/nonexistent \
eval "$_ffconf" > "$PREFIX/.logs/ffmpeg-configure.log" 2>&1 || {
  cat "$PREFIX/.logs/ffmpeg-configure.log" >&2
  die "FFmpeg configure failed"
}

run make -j "$MJOBS"
run make install

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
