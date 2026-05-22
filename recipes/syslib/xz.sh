# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="xz"
PKG_VERSION="${PKG_VERSION_XZ:-5.8.3}"
PKG_GITHUB_REPO="tukaani-project/xz"
PKG_URL="https://github.com/tukaani-project/xz/releases/download/v${PKG_VERSION}/xz-${PKG_VERSION}.tar.xz"
PKG_FILENAME="xz-${PKG_VERSION}.tar.xz"
# Transitive utility — xz ships liblzma.pc (not xz.pc), override PKG_PC_FILES.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="liblzma"

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-doc --disable-nls \
    --disable-xz --disable-xzdec --disable-lzmadec \
    --disable-lzmainfo --disable-lzma-links \
    --disable-scripts \
    CFLAGS="$CFLAGS -fPIC"
}
