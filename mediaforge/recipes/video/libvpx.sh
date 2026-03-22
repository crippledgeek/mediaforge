PKG_NAME="libvpx"
PKG_VERSION="${PKG_VERSION_LIBVPX:-1.15.2}"
PKG_GITHUB_REPO="webmproject/libvpx"
PKG_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libvpx-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvpx"

pkg_prepare() {
  if [ "$OS_MACOS" = true ]; then
    log "Applying Darwin patch"
    sed "s/,--version-script//g" build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
    sed "s/-Wl,--no-undefined -Wl,-soname/-Wl,-undefined,error -Wl,-install_name/g" \
      build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
  fi
}

pkg_configure() {
  execute ./configure --prefix="$PREFIX" --disable-unit-tests --disable-shared \
    --disable-examples --as=yasm --enable-vp9-highbitdepth
}
