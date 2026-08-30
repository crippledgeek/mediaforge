# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="VapourSynth"
PKG_VERSION="${PKG_VERSION_VAPOURSYNTH:-73}"
PKG_GITHUB_REPO="vapoursynth/vapoursynth"
PKG_URL="https://github.com/vapoursynth/vapoursynth/archive/R${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vapoursynth"

pkg_configure() { :; }
pkg_build() { :; }

# mf_dest_prefix, not $PREFIX: a shell cp writes past the stage (GH-68).
pkg_install() {
  _dest=$(mf_dest_prefix)
  mkdir -p "$_dest/include/vapoursynth" || die "Failed to create vapoursynth include dir"
  cp -r "include/." "$_dest/include/vapoursynth/"
}
