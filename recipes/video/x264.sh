PKG_NAME="x264"
PKG_VERSION="${PKG_VERSION_X264:-0480cb05}"
PKG_URL="https://code.videolan.org/videolan/x264/-/archive/${PKG_VERSION}/x264-${PKG_VERSION}.tar.gz"
PKG_FILENAME="x264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx264"
PKG_GPL=true

pkg_configure() {
  if [ "$OS_LINUX" = true ]; then
    run ./configure --prefix="$PREFIX" --enable-static --enable-pic \
      CXXFLAGS="-fPIC $CXXFLAGS"
  else
    run ./configure --prefix="$PREFIX" --enable-static --enable-pic
  fi
}

pkg_post_install() {
  run make install-lib-static
}
