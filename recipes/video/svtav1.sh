# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="svtav1"
PKG_VERSION="${PKG_VERSION_SVTAV1:-3.1.2}"
PKG_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${PKG_VERSION}/SVT-AV1-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="svtav1-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsvtav1"
PKG_MUTEX_GROUP="av1-enc"
PKG_CMAKE_BUILD_TYPE="Release"

pkg_configure() {
  cd "$DISTDIR/svtav1-${PKG_VERSION}/Build/linux" || die "Failed to cd to SVT-AV1 build dir"
  # LTO bakes GCC-version-specific GIMPLE bytecode into libSvtAv1Enc.a, which
  # breaks downstream links after any GCC major bump. Default off; opt in via
  # --enable-lto when the binary won't outlive the toolchain.
  _lto_flag=OFF
  [ "$ENABLE_LTO" = true ] && _lto_flag=ON
  mf_cmake -DENABLE_SHARED=off \
    -DBUILD_SHARED_LIBS=OFF -DSVT_AV1_LTO=$_lto_flag \
    ../.. -G"Unix Makefiles"
}

# No pkg_post_install: upstream installs SvtAv1Enc.pc itself. Source/Lib/
# CMakeLists.txt configure_file()s it into the build dir and install()s it to
# ${CMAKE_INSTALL_LIBDIR}/pkgconfig, and the recipe's stamp records
# lib/pkgconfig/SvtAv1Enc.pc as STAGED -- which only that install can have done.
# The `cp` that used to be here installed the same file a second time, into the
# live prefix where nothing recorded it (GH-68).
