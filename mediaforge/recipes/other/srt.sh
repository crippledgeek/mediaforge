PKG_NAME="srt"
PKG_VERSION="${PKG_VERSION_SRT:-1.5.4}"
PKG_GITHUB_REPO="Haivision/srt"
PKG_URL="https://github.com/Haivision/srt/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="srt-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsrt"
PKG_NONFREE=true

pkg_configure() {
  export OPENSSL_ROOT_DIR="$PREFIX"
  export OPENSSL_LIB_DIR="$PREFIX/lib"
  export OPENSSL_INCLUDE_DIR="$PREFIX/include/"
  run cmake . -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DUSE_STATIC_LIBSTDCXX=ON
}

pkg_install() {
  run make install
}

pkg_post_install() {
  if [ -n "$LDEXEFLAGS" ]; then
    _pc="$PREFIX/lib/pkgconfig/srt.pc"
    awk '/^Libs/ {gsub(/-lgcc_s/, "-lgcc_eh")} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
  fi
}
