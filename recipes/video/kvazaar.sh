# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="kvazaar"
PKG_VERSION="${PKG_VERSION_KVAZAAR:-2.3.1}"
PKG_GITHUB_REPO="ultravideo/kvazaar"
PKG_URL="https://github.com/ultravideo/kvazaar/releases/download/v${PKG_VERSION}/kvazaar-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libkvazaar"
PKG_MUTEX_GROUP="h265"
