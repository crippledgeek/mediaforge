PKG_NAME="x264"
PKG_VERSION="0480cb05"
PKG_URL="https://code.videolan.org/videolan/x264/-/archive/${PKG_VERSION}/x264-${PKG_VERSION}.tar.gz"
PKG_FILENAME="x264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx264"
PKG_GPL=true

pkg_configure() {
  if [ "$IS_LINUX" = true ]; then
    execute ./configure --prefix="$WORKSPACE" --enable-static --enable-pic \
      CXXFLAGS="-fPIC $CXXFLAGS"
  else
    execute ./configure --prefix="$WORKSPACE" --enable-static --enable-pic
  fi
}

pkg_post_install() {
  execute make install-lib-static
}
