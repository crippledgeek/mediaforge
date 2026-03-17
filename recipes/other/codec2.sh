PKG_NAME="codec2"
PKG_VERSION="${PKG_VERSION_CODEC2:-1.2.0}"
PKG_GITHUB_REPO="drowe67/codec2"
PKG_URL="https://github.com/drowe67/codec2/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="codec2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libcodec2"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DUNITTEST=OFF"
