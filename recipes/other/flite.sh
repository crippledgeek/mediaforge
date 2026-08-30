# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="flite"
PKG_VERSION="${PKG_VERSION_FLITE:-2.2}"
PKG_URL="https://github.com/festvox/flite/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="flite-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="festvox/flite"
PKG_FFMPEG_OPT="--enable-libflite"

# flite has old C code incompatible with C23 (GCC 15+)
PKG_C_STD="gnu11"

pkg_configure() {
  # FFmpeg's asrc_flite filter uses a streaming callback (writes samples into
  # AVAudioFifo) and never invokes flite's audio output path. So 'none' is the
  # right default for ffmpeg-only consumption — drops au_alsa.o and avoids the
  # snd_pcm_* unresolved-symbol cascade at FFmpeg's static link step.
  # Override via --flite-audio=alsa|pulseaudio|oss|sun if you also want a
  # working standalone libflite-audio with the chosen backend; FFmpeg will
  # then need the matching audio library available at link time.
  run ./configure --prefix="$PREFIX" --with-pic --with-audio="$FLITE_AUDIO"
}

# Build only libraries (parallel make races on flite_voice_list.c for tools)
pkg_build() {
  run make -j "$MJOBS" -C include
  run make -j "$MJOBS" -C src
  run make -j "$MJOBS" -C lang
}

pkg_install() {
  # flite's build dir uses its own triplet, not gcc's
  _builddir=$(find build -maxdepth 1 -type d ! -name build | head -1)
  if [ -z "$_builddir" ]; then
    die "Cannot find flite build directory"
  fi
  # mf_dest_prefix, not $PREFIX: flite's own `make install` is skipped (see
  # pkg_build), and a shell cp writes past the stage (GH-68).
  _dest=$(mf_dest_prefix)
  mf_dest_mkdir include/flite lib
  run cp include/*.h "$_dest/include/flite/"
  run cp "$_builddir"/lib/*.a "$_dest/lib/"
}
