PKG_NAME="fribidi"
PKG_VERSION="${PKG_VERSION_FRIBIDI:-1.0.16}"
PKG_GITHUB_REPO="fribidi/fribidi"
PKG_URL="https://github.com/fribidi/fribidi/releases/download/v${PKG_VERSION}/fribidi-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfribidi"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Ddocs=false -Dtests=false
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
