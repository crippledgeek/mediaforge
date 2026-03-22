PKG_NAME="VapourSynth"
PKG_VERSION="${PKG_VERSION_VAPOURSYNTH:-73}"
PKG_GITHUB_REPO="vapoursynth/vapoursynth"
PKG_URL="https://github.com/vapoursynth/vapoursynth/archive/R${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vapoursynth"

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  mkdir -p "$PREFIX/include/vapoursynth" || die "Failed to create vapoursynth include dir"
  cp -r "include/." "$PREFIX/include/vapoursynth/"
}
