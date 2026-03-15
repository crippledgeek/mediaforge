PKG_NAME="svtav1"
PKG_VERSION="3.1.2"
PKG_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${PKG_VERSION}/SVT-AV1-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="svtav1-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsvtav1"

pkg_configure() {
  cd "$PACKAGES/svtav1-${PKG_VERSION}/Build/linux" || die "Failed to cd to SVT-AV1 build dir"
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DENABLE_SHARED=off \
    -DBUILD_SHARED_LIBS=OFF ../.. -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
}

pkg_post_install() {
  execute cp SvtAv1Enc.pc "$WORKSPACE/lib/pkgconfig/"
}
