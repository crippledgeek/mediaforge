PKG_NAME="brotli"
PKG_VERSION="${PKG_VERSION_BROTLI:-1.2.0}"
PKG_GITHUB_REPO="google/brotli"
PKG_URL="https://github.com/google/brotli/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="brotli-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="\
  -DBROTLI_DISABLE_TESTS=On \
  -DBROTLI_BUNDLED_MODE=Off \
  -DCMAKE_POSITION_INDEPENDENT_CODE=On"

# brotli's cmake config builds both shared and static. We only want static —
# remove the .so files post-install so consumers' static probes pick the .a.
pkg_post_install() {
  rm -f "$PREFIX/lib/libbrotlicommon.so"* \
        "$PREFIX/lib/libbrotlidec.so"* \
        "$PREFIX/lib/libbrotlienc.so"* 2>/dev/null
}
