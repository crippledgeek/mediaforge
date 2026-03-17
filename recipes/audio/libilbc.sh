PKG_NAME="libilbc"
PKG_VERSION="${PKG_VERSION_LIBILBC:-3.0.4}"
PKG_GITHUB_REPO="nicoboss/libilbc"
PKG_URL="https://github.com/nicoboss/libilbc/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libilbc-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libilbc"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release"
