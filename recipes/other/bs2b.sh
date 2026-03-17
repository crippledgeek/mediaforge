PKG_NAME="bs2b"
PKG_VERSION="${PKG_VERSION_BS2B:-3.1.0}"
PKG_URL="https://downloads.sourceforge.net/bs2b/libbs2b-${PKG_VERSION}.tar.lzma"
PKG_FILENAME="libbs2b-${PKG_VERSION}.tar.lzma"
PKG_DIRNAME="libbs2b-${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-libbs2b"

# bs2b has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
