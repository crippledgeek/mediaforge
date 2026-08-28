# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="openjpeg"
PKG_VERSION="${PKG_VERSION_OPENJPEG:-2.5.3}"
PKG_GITHUB_REPO="uclouvain/openjpeg"
PKG_URL="https://github.com/uclouvain/openjpeg/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openjpeg-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenjpeg"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="-DBUILD_CODEC=OFF"
