PKG_NAME="rubberband"
PKG_VERSION="${PKG_VERSION_RUBBERBAND:-4.0.0}"
PKG_GITHUB_REPO="breakfastquay/rubberband"
PKG_URL="https://breakfastquay.com/files/releases/rubberband-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-librubberband"
PKG_GPL=true
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dfft=builtin -Dresampler=builtin -Dtests=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
