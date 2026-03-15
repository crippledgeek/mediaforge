PKG_NAME="xvidcore"
PKG_VERSION="1.3.7"
PKG_URL="https://downloads.xvid.com/downloads/xvidcore-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxvid"
PKG_GPL=true

pkg_configure() {
  cd build/generic || die "Failed to cd to build/generic"
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}

pkg_post_install() {
  if [ -f "$WORKSPACE/lib/libxvidcore.4.dylib" ]; then
    rm -f "$WORKSPACE/lib/libxvidcore.4.dylib"
  fi
  if [ -f "$WORKSPACE/lib/libxvidcore.so" ]; then
    rm -f "$WORKSPACE"/lib/libxvidcore.so*
  fi
}
