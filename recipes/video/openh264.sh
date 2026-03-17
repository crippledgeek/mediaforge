PKG_NAME="openh264"
PKG_VERSION="${PKG_VERSION_OPENH264:-2.6.0}"
PKG_GITHUB_REPO="cisco/openh264"
PKG_URL="https://github.com/cisco/openh264/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openh264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenh264"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib"
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
