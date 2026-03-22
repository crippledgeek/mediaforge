PKG_NAME="fontconfig"
PKG_VERSION="${PKG_VERSION_FONTCONFIG:-2.15.0}"
PKG_GITHUB_REPO="fontconfig/fontconfig"
PKG_URL="https://www.freedesktop.org/software/fontconfig/release/fontconfig-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfontconfig"
PKG_REQUIRES_MESON=true

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
