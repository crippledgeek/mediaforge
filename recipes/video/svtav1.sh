PKG_NAME="svtav1"
PKG_VERSION="${PKG_VERSION_SVTAV1:-3.1.2}"
PKG_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${PKG_VERSION}/SVT-AV1-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="svtav1-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsvtav1"
PKG_MUTEX_GROUP="av1-enc"

pkg_configure() {
  cd "$DISTDIR/svtav1-${PKG_VERSION}/Build/linux" || die "Failed to cd to SVT-AV1 build dir"
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DENABLE_SHARED=off \
    -DBUILD_SHARED_LIBS=OFF ../.. -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
}

pkg_post_install() {
  run cp SvtAv1Enc.pc "$PREFIX/lib/pkgconfig/"
}
