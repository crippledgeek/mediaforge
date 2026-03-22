PKG_NAME="rubberband"
PKG_VERSION="${PKG_VERSION_RUBBERBAND:-4.0.0}"
PKG_GITHUB_REPO="breakfastquay/rubberband"
PKG_URL="https://breakfastquay.com/files/releases/rubberband-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-librubberband"
PKG_GPL=true
PKG_REQUIRES_MESON=true

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Dfft=builtin -Dresampler=builtin -Dtests=disabled
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
