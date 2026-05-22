# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="opus"
PKG_VERSION="${PKG_VERSION_OPUS:-1.6}"
PKG_URL="https://downloads.xiph.org/releases/opus/opus-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopus"
