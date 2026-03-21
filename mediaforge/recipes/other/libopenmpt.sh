PKG_NAME="libopenmpt"
PKG_VERSION="${PKG_VERSION_LIBOPENMPT:-0.7.14}"
PKG_URL="https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${PKG_VERSION}+release.autotools.tar.gz"
PKG_FILENAME="libopenmpt-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenmpt"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-examples --disable-tests --disable-openmpt123 \
    --without-mpg123 --without-portaudio --without-portaudiocpp
}
