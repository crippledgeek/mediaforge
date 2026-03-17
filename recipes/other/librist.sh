PKG_NAME="librist"
PKG_VERSION="${PKG_VERSION_LIBRIST:-0.2.12}"
PKG_GITHUB_REPO="xiph/librist"
PKG_URL="https://code.videolan.org/rist/librist/-/archive/v${PKG_VERSION}/librist-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="librist-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librist"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dbuilt_tools=false -Dtest=false
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
