# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="fdk_aac"
PKG_VERSION="${PKG_VERSION_FDK_AAC:-2.0.3}"
PKG_URL="https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="fdk-aac-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="mstorsjo/fdk-aac"
PKG_FFMPEG_OPT="--enable-libfdk-aac"
PKG_NONFREE=true
PKG_MUTEX_GROUP="aac"
PKG_CONFIGURE_FLAGS="--enable-pic"

pkg_prepare() {
  run autoreconf -fiv
}
