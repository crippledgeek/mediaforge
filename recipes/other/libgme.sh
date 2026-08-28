# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libgme"
PKG_VERSION="${PKG_VERSION_LIBGME:-0.6.3}"
PKG_GITHUB_REPO="libgme/game-music-emu"
# The release asset, not /archive/refs/tags/. GitHub GENERATES a tag archive on
# request, so its bytes are not a fixed artifact (#19). Upstream publishes no
# digest beside it, so this buys byte-stability only -- the sidecar stays
# locally calculated.
PKG_URL="https://github.com/libgme/game-music-emu/releases/download/${PKG_VERSION}/libgme-${PKG_VERSION}-src.tar.gz"
PKG_FILENAME="libgme-${PKG_VERSION}-src.tar.gz"
PKG_FFMPEG_OPT="--enable-libgme"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="-DENABLE_UBSAN=OFF"
