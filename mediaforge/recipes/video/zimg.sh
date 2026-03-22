PKG_NAME="zimg"
PKG_VERSION="${PKG_VERSION_ZIMG:-3.0.6}"
PKG_GITHUB_REPO="sekrit-twc/zimg"
PKG_URL="https://github.com/sekrit-twc/zimg/archive/refs/tags/release-${PKG_VERSION}.tar.gz"
PKG_FILENAME="zimg-${PKG_VERSION}.tar.gz"
PKG_DIRNAME="zimg"
PKG_FFMPEG_OPT="--enable-libzimg"

pkg_prepare() {
  cd "zimg-release-${PKG_VERSION}" || die "Failed to cd to zimg source"
  run "$PREFIX/bin/libtoolize" -i -f -q
  run ./autogen.sh --prefix="$PREFIX"
}
