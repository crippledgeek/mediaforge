PKG_NAME="openssl"
PKG_VERSION="3.5.4"
PKG_URL="https://github.com/openssl/openssl/archive/refs/tags/openssl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="openssl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-openssl"
PKG_NONFREE=true

pkg_configure() {
  execute ./Configure --prefix="$WORKSPACE" --openssldir="$WORKSPACE" --libdir="lib" \
    --with-zlib-include="$WORKSPACE/include/" --with-zlib-lib="$WORKSPACE/lib" \
    no-shared zlib
}

pkg_install() {
  execute make install_sw
}
