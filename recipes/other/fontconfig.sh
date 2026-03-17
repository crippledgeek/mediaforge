PKG_NAME="fontconfig"
PKG_VERSION="${PKG_VERSION_FONTCONFIG:-2.15.0}"
PKG_GITHUB_REPO="fontconfig/fontconfig"
PKG_URL="https://www.freedesktop.org/software/fontconfig/release/fontconfig-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfontconfig"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
