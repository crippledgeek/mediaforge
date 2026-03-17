PKG_NAME="librtmp"
PKG_VERSION="${PKG_VERSION_LIBRTMP:-fa8646d}"
PKG_URL="https://git.ffmpeg.org/gitweb/rtmpdump.git/snapshot/${PKG_VERSION}.tar.gz"
PKG_FILENAME="rtmpdump-${PKG_VERSION}.tar.gz"

# librtmp has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  :
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  execute make SYS=posix prefix="$WORKSPACE" \
    SHARED= CRYPTO=OPENSSL \
    XCFLAGS="$CFLAGS -I$WORKSPACE/include" \
    XLDFLAGS="-L$WORKSPACE/lib" \
    LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
}

pkg_install() {
  execute make SYS=posix prefix="$WORKSPACE" SHARED= install
}

pkg_post_install() {
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-librtmp"
}
