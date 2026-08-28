# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libtheora"
PKG_VERSION="${PKG_VERSION_LIBTHEORA:-1.2.0}"
PKG_URL="https://downloads.xiph.org/releases/theora/libtheora-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtheora"

# libtheora 1.2.0 has older C code incompatible with C23
PKG_C_STD="gnu11"

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
