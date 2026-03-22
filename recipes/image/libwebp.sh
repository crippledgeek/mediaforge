PKG_NAME="libwebp"
PKG_VERSION="${PKG_VERSION_LIBWEBP:-1.6.0}"
PKG_GITHUB_REPO="webmproject/libwebp"
PKG_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libwebp-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libwebp"

pkg_configure() {
  rm -rf build && mkdir -p build
  cd build || die "Failed to cd to libwebp build dir"
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF ../
}
