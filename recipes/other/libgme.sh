PKG_NAME="libgme"
PKG_VERSION="${PKG_VERSION_LIBGME:-0.6.3}"
PKG_GITHUB_REPO="libgme/game-music-emu"
PKG_URL="https://github.com/libgme/game-music-emu/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="game-music-emu-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libgme"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DENABLE_UBSAN=OFF"
