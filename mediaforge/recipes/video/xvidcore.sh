PKG_NAME="xvidcore"
PKG_VERSION="${PKG_VERSION_XVIDCORE:-1.3.7}"
PKG_URL="https://downloads.xvid.com/downloads/xvidcore-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxvid"
PKG_GPL=true

# xvidcore 1.3.7 has old C code incompatible with C23
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  cd build/generic || die "Failed to cd to build/generic"
  execute ./configure --prefix="$PREFIX" --disable-shared --enable-static
}

pkg_post_install() {
  if [ -f "$PREFIX/lib/libxvidcore.4.dylib" ]; then
    rm -f "$PREFIX/lib/libxvidcore.4.dylib"
  fi
  if [ -f "$PREFIX/lib/libxvidcore.so" ]; then
    rm -f "$PREFIX"/lib/libxvidcore.so*
  fi
}
