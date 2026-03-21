PKG_NAME="soxr"
PKG_VERSION="${PKG_VERSION_SOXR:-0.1.3}"
PKG_URL="https://sourceforge.net/projects/soxr/files/soxr-${PKG_VERSION}-Source.tar.xz/download?use_mirror=gigenet"
PKG_FILENAME="soxr-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libsoxr"

pkg_configure() {
  mkdir build && cd build || die "Failed to create/enter soxr build dir"
  execute cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DBUILD_SHARED_LIBS:bool=off -DWITH_OPENMP:bool=off \
    -DBUILD_TESTS:bool=off -Wno-dev ..
}
