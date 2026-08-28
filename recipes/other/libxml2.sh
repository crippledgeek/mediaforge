# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libxml2"
PKG_VERSION="${PKG_VERSION_LIBXML2:-2.13.6}"
PKG_GITHUB_REPO="GNOME/libxml2"
PKG_URL="https://github.com/GNOME/libxml2/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libxml2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxml2"
# Transitive utility — libxml2 ships libxml-2.0.pc, override PKG_PC_FILES.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="libxml-2.0"

PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="\
  -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF"
