# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="FreeType2-hb"
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"
# Transitive utility — freetype2.pc not installed (system has it). Same .pc
# file as the freetype2 recipe — this is a circular-dep rebuild after harfbuzz.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="freetype2"

pkg_configure() {
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --with-harfbuzz=yes
}
