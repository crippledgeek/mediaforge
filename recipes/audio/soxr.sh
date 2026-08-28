# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="soxr"
PKG_VERSION="${PKG_VERSION_SOXR:-0.1.3}"
PKG_URL="https://sourceforge.net/projects/soxr/files/soxr-${PKG_VERSION}-Source.tar.xz/download?use_mirror=gigenet"
PKG_FILENAME="soxr-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libsoxr"
PKG_CMAKE_BUILD_TYPE="Release"

pkg_configure() {
  mkdir build || die "Failed to create soxr build dir"
  cd build || die "Failed to enter soxr build dir"
  mf_cmake \
    -DBUILD_SHARED_LIBS:bool=off -DWITH_OPENMP:bool=off \
    -DBUILD_TESTS:bool=off -Wno-dev ..
}
