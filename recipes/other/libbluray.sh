PKG_NAME="libbluray"
PKG_VERSION="${PKG_VERSION_LIBBLURAY:-1.3.4}"
PKG_GITHUB_REPO="videolan/libbluray"
PKG_URL="https://download.videolan.org/pub/videolan/libbluray/${PKG_VERSION}/libbluray-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-libbluray"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-bdjava-jar --disable-doxygen-doc --disable-examples
}
