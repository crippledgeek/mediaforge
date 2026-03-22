PKG_NAME="openh264"
PKG_VERSION="${PKG_VERSION_OPENH264:-2.6.0}"
PKG_GITHUB_REPO="cisco/openh264"
PKG_URL="https://github.com/cisco/openh264/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openh264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenh264"
PKG_REQUIRES_MESON=true

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib"
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}

# openh264 is C++ but its pkgconfig omits -lstdc++ for static linking
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/openh264.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
