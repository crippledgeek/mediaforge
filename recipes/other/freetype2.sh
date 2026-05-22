# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="FreeType2"
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfreetype"
PKG_CONFIGURE_FLAGS="--without-harfbuzz"
