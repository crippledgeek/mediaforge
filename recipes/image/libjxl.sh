PKG_NAME="libjxl"
PKG_VERSION="${PKG_VERSION_LIBJXL:-0.11.1}"
PKG_GITHUB_REPO="libjxl/libjxl"
PKG_URL="https://github.com/libjxl/libjxl/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libjxl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libjxl"

pkg_prepare() {
  # Fix static linking: libjxl_threads needs -lstdc++ in its pkgconfig Libs
  patch -p1 < "$SCRIPT_DIR/patches/libjxl-static-linking.patch" 2>/dev/null || true
  run ./deps.sh
}

pkg_configure() {
  run cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=off -DENABLE_STATIC=ON \
    -DCMAKE_BUILD_TYPE=Release -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_JPEGLI=ON \
    -DJPEGXL_TEST_TOOLS=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DBUILD_TESTING=OFF .
}
