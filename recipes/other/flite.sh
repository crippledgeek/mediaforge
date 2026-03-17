PKG_NAME="flite"
PKG_VERSION="${PKG_VERSION_FLITE:-2.2}"
PKG_URL="https://github.com/festvox/flite/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="flite-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="festvox/flite"
PKG_FFMPEG_OPT="--enable-libflite"

# flite has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --with-pic
}

pkg_install() {
  execute make install
}
