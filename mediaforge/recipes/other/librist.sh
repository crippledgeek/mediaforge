PKG_NAME="librist"
PKG_VERSION="${PKG_VERSION_LIBRIST:-0.2.11}"
PKG_GITHUB_REPO="xiph/librist"
PKG_URL="https://code.videolan.org/rist/librist/-/archive/v${PKG_VERSION}/librist-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="librist-v${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librist"
PKG_REQUIRES_MESON=true

# librist 0.2.11 uses -pedantic-errors which promotes -Wdiscarded-qualifiers
# to a hard error on GCC 15
pkg_prepare() {
  CFLAGS="$CFLAGS -Wno-error=discarded-qualifiers"
  export CFLAGS
}

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
