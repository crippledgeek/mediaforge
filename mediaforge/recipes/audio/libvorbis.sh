PKG_NAME="libvorbis"
PKG_VERSION="${PKG_VERSION_LIBVORBIS:-1.3.7}"
PKG_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvorbis"

pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
  patch -p1 < "$SCRIPT_DIR/patches/libvorbis-cpusubtype.patch" 2>/dev/null || true
  run ./autogen.sh --prefix="$PREFIX"
}

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --with-ogg-libraries="$PREFIX/lib" \
    --with-ogg-includes="$PREFIX/include/" \
    --enable-static --disable-shared --disable-oggtest
}
