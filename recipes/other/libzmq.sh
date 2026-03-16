PKG_NAME="libzmq"
PKG_VERSION="${PKG_VERSION_LIBZMQ:-4.3.5}"
PKG_GITHUB_REPO="zeromq/libzmq"
PKG_URL="https://github.com/zeromq/libzmq/releases/download/v${PKG_VERSION}/zeromq-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libzmq"

pkg_prepare() {
  if [ "$IS_DARWIN" = true ]; then
    export XML_CATALOG_FILES=/usr/local/etc/xml/catalog
  fi
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}

pkg_build() {
  sed "s/stats_proxy stats = {0}/stats_proxy stats = {{{0, 0}, {0, 0}}, {{0, 0}, {0, 0}}}/g" \
    src/proxy.cpp > src/proxy.cpp.tmp && mv src/proxy.cpp.tmp src/proxy.cpp
  execute make -j "$MJOBS"
}
