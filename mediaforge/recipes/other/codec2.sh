PKG_NAME="codec2"
PKG_VERSION="${PKG_VERSION_CODEC2:-1.2.0}"
PKG_GITHUB_REPO="drowe67/codec2"
PKG_URL="https://github.com/drowe67/codec2/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="codec2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libcodec2"

# Rename lsp functions to avoid symbol collision with libspeex
# (both ship lpc_to_lsp/lsp_to_lpc — upstream PR #60 was not merged)
pkg_prepare() {
  CFLAGS="$CFLAGS -Dlpc_to_lsp=codec2_lpc_to_lsp -Dlsp_to_lpc=codec2_lsp_to_lpc"
  export CFLAGS
}

pkg_configure() {
  make_dir build
  execute cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DUNITTEST=OFF \
    -B build .
}

pkg_build() {
  execute cmake --build build -j "$MJOBS"
}

pkg_install() {
  execute cmake --install build
}
