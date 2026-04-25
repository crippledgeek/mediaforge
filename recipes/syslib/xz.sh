PKG_NAME="xz"
PKG_VERSION="${PKG_VERSION_XZ:-5.8.3}"
PKG_GITHUB_REPO="tukaani-project/xz"
PKG_URL="https://github.com/tukaani-project/xz/releases/download/v${PKG_VERSION}/xz-${PKG_VERSION}.tar.xz"
PKG_FILENAME="xz-${PKG_VERSION}.tar.xz"

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-doc --disable-nls \
    --disable-xz --disable-xzdec --disable-lzmadec \
    --disable-lzmainfo --disable-lzma-links \
    --disable-scripts \
    CFLAGS="$CFLAGS -fPIC"
}
