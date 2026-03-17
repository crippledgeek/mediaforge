PKG_NAME="libxml2"
PKG_VERSION="${PKG_VERSION_LIBXML2:-2.13.6}"
PKG_GITHUB_REPO="GNOME/libxml2"
PKG_URL="https://github.com/GNOME/libxml2/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libxml2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxml2"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --without-python --without-readline --without-lzma \
    --without-debug --without-icu --with-zlib="$WORKSPACE"
}
