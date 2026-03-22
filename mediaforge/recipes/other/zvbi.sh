PKG_NAME="zvbi"
PKG_VERSION="${PKG_VERSION_ZVBI:-0.2.44}"
PKG_GITHUB_REPO="zapping-vbi/zvbi"
PKG_URL="https://github.com/zapping-vbi/zvbi/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="zvbi-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libzvbi"
PKG_NONFREE=true

pkg_prepare() {
  run ./autogen.sh --prefix="$PREFIX"
}

pkg_configure() {
  run ./configure CFLAGS="-I$PREFIX/include/libpng16 $CFLAGS" \
    --prefix="$PREFIX" --enable-static --disable-shared
}
