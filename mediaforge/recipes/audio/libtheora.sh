PKG_NAME="libtheora"
PKG_VERSION="${PKG_VERSION_LIBTHEORA:-1.2.0}"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/theora/libtheora-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtheora"

# libtheora 1.2.0 has older C code incompatible with C23
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --with-ogg-libraries="$PREFIX/lib" \
    --with-ogg-includes="$PREFIX/include/" \
    --with-vorbis-libraries="$PREFIX/lib" \
    --with-vorbis-includes="$PREFIX/include/" \
    --enable-static --disable-shared \
    --disable-oggtest --disable-vorbistest \
    --disable-examples --disable-spec
}
