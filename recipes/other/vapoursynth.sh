PKG_NAME="VapourSynth"
PKG_VERSION="73"
PKG_URL="https://github.com/vapoursynth/vapoursynth/archive/R${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vapoursynth"

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  mkdir -p "$WORKSPACE/include/vapoursynth" || die "Failed to create vapoursynth include dir"
  cp -r "include/." "$WORKSPACE/include/vapoursynth/"
}
