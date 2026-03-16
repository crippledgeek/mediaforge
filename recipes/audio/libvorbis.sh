PKG_NAME="libvorbis"
PKG_VERSION="${PKG_VERSION_LIBVORBIS:-1.3.7}"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvorbis"

pkg_prepare() {
  sed "s/-force_cpusubtype_ALL//g" configure.ac > configure.ac.tmp \
    && mv configure.ac.tmp configure.ac
  execute ./autogen.sh --prefix="$WORKSPACE"
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" \
    --with-ogg-libraries="$WORKSPACE/lib" \
    --with-ogg-includes="$WORKSPACE/include/" \
    --enable-static --disable-shared --disable-oggtest
}
