PKG_NAME="libvorbis"
PKG_VERSION="${PKG_VERSION_LIBVORBIS:-1.3.7}"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvorbis"

pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
  sed "s/-force_cpusubtype_ALL//g" configure.ac > configure.ac.tmp \
    && mv configure.ac.tmp configure.ac
  run ./autogen.sh --prefix="$PREFIX"
}

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --with-ogg-libraries="$PREFIX/lib" \
    --with-ogg-includes="$PREFIX/include/" \
    --enable-static --disable-shared --disable-oggtest
}
