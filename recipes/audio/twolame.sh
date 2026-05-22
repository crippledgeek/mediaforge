# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="twolame"
PKG_VERSION="${PKG_VERSION_TWOLAME:-0.4.0}"
PKG_URL="https://sourceforge.net/projects/twolame/files/twolame/${PKG_VERSION}/twolame-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="twolame-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtwolame"
