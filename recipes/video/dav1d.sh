PKG_NAME="dav1d"
PKG_VERSION="1.5.3"
PKG_URL="https://code.videolan.org/videolan/dav1d/-/archive/${PKG_VERSION}/dav1d-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libdav1d"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  _cflagsbackup="$CFLAGS"
  if [ "$IS_MACOS_SILICON" = true ]; then
    export CFLAGS="-arch arm64"
  fi
  make_dir build
  execute meson build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib"
  if [ "$IS_MACOS_SILICON" = true ]; then
    export CFLAGS="$_cflagsbackup"
  fi
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
