PKG_NAME="dav1d"
PKG_VERSION="${PKG_VERSION_DAV1D:-1.5.3}"
PKG_URL="https://code.videolan.org/videolan/dav1d/-/archive/${PKG_VERSION}/dav1d-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libdav1d"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  _cflagsbackup="$CFLAGS"
  if [ "$OS_MACOS_ARM" = true ]; then
    export CFLAGS="-arch arm64"
  fi
  rm -rf build && mkdir -p build
  run meson build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib"
  if [ "$OS_MACOS_ARM" = true ]; then
    export CFLAGS="$_cflagsbackup"
  fi
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
