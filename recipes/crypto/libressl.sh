PKG_NAME="libressl"
PKG_VERSION="${PKG_VERSION_LIBRESSL:-4.0.0}"
PKG_URL="https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libressl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtls"
PKG_MUTEX_GROUP="tls"

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-asm \
    --disable-tests
}

pkg_post_install() {
  if [ ! -f "$PREFIX/lib/pkgconfig/libtls.pc" ]; then
    warn "libressl: libtls.pc not found at $PREFIX/lib/pkgconfig/libtls.pc"
  fi
}
