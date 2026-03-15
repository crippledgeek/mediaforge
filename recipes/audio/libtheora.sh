PKG_NAME="libtheora"
PKG_VERSION="1.2.0"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/theora/libtheora-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtheora"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" \
    --with-ogg-libraries="$WORKSPACE/lib" \
    --with-ogg-includes="$WORKSPACE/include/" \
    --with-vorbis-libraries="$WORKSPACE/lib" \
    --with-vorbis-includes="$WORKSPACE/include/" \
    --enable-static --disable-shared \
    --disable-oggtest --disable-vorbistest \
    --disable-examples --disable-spec
}
