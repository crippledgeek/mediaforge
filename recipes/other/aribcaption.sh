# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# ARIB STD-B24 captions. MIT.
PKG_NAME="aribcaption"
PKG_VERSION="${PKG_VERSION_LIBARIBCAPTION:-1.1.1}"
PKG_GITHUB_REPO="xqq/libaribcaption"
PKG_URL="https://github.com/xqq/libaribcaption/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libaribcaption-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libaribcaption"
PKG_CMAKE=true

# Static library only; no tests. FreeType + Fontconfig text-rendering backends
# resolve against the freetype2/fontconfig already built earlier in _order.conf.
# Installs libaribcaption.pc (FFmpeg probes "libaribcaption").
PKG_CMAKE_FLAGS="\
  -DCMAKE_BUILD_TYPE=Release \
  -DARIBCC_BUILD_TESTS=OFF \
  -DARIBCC_SHARED_LIBRARY=OFF \
  -DARIBCC_USE_FREETYPE=ON \
  -DARIBCC_USE_FONTCONFIG=ON"
