PKG_NAME="libjxl"
PKG_VERSION="${PKG_VERSION_LIBJXL:-0.11.1}"
PKG_GITHUB_REPO="libjxl/libjxl"
PKG_URL="https://github.com/libjxl/libjxl/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libjxl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libjxl"

pkg_prepare() {
  # Fix static linking: libjxl_threads needs -lstdc++ in its pkgconfig Libs
  # (upstream bug — jxl.cmake does this for libjxl but jxl_threads.cmake doesn't)

  # 1) Add @JPEGXL_THREADS_PUBLIC_LIBS@ placeholder to the .pc.in template
  sed 's/-ljxl_threads/-ljxl_threads @JPEGXL_THREADS_PUBLIC_LIBS@/' \
    lib/threads/libjxl_threads.pc.in > lib/threads/libjxl_threads.pc.in.tmp \
    && mv lib/threads/libjxl_threads.pc.in.tmp lib/threads/libjxl_threads.pc.in

  # 2) Define the variable in jxl_threads.cmake (static build branch)
  sed '/set(JPEGXL_REQUIRES_TYPE "Requires")/a\
  set(JPEGXL_THREADS_PUBLIC_LIBS "-lm ${PKGCONFIG_CXX_LIB}")' \
    lib/jxl_threads.cmake > lib/jxl_threads.cmake.tmp \
    && mv lib/jxl_threads.cmake.tmp lib/jxl_threads.cmake

  execute ./deps.sh
}

pkg_configure() {
  execute cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=off -DENABLE_STATIC=ON \
    -DCMAKE_BUILD_TYPE=Release -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_JPEGLI=ON \
    -DJPEGXL_TEST_TOOLS=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DBUILD_TESTING=OFF .
}
