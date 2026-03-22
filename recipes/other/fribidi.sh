PKG_NAME="fribidi"
PKG_VERSION="${PKG_VERSION_FRIBIDI:-1.0.16}"
PKG_GITHUB_REPO="fribidi/fribidi"
PKG_URL="https://github.com/fribidi/fribidi/releases/download/v${PKG_VERSION}/fribidi-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfribidi"
PKG_REQUIRES_MESON=true

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Ddocs=false -Dtests=false
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
