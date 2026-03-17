PKG_NAME="harfbuzz"
PKG_VERSION="${PKG_VERSION_HARFBUZZ:-10.4.0}"
PKG_GITHUB_REPO="harfbuzz/harfbuzz"
PKG_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${PKG_VERSION}/harfbuzz-${PKG_VERSION}.tar.xz"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
