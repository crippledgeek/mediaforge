# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="bs2b"
PKG_VERSION="${PKG_VERSION_BS2B:-3.1.0}"
PKG_URL="https://downloads.sourceforge.net/bs2b/libbs2b-${PKG_VERSION}.tar.lzma"
PKG_FILENAME="libbs2b-${PKG_VERSION}.tar.lzma"
PKG_FFMPEG_OPT="--enable-libbs2b"
PKG_CONFIGURE_FLAGS="--disable-sndfile"

# bs2b has old C code incompatible with C23 (GCC 15+)
PKG_C_STD="gnu11"

pkg_prepare() {
  LIBS="-lm"
  export LIBS
}
