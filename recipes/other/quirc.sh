# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="quirc"
PKG_VERSION="${PKG_VERSION_LIBQUIRC:-1.2}"
PKG_GITHUB_REPO="dlbeer/quirc"
PKG_URL="https://github.com/dlbeer/quirc/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="quirc-${PKG_VERSION}.tar.gz"
# QR decode filter. ISC license.
# quirc ships a Makefile and NO pkg-config file, but FFmpeg's
# --enable-libquirc probes pkg-config name 'libquirc'. Build libquirc.a,
# install header + lib, and synthesize libquirc.pc. Requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libquirc"
else
  PKG_DISABLED=true
fi

pkg_configure() { :; }

# The library doesn't need SDL, but quirc's Makefile globally sets
# SDL_CFLAGS := $(shell pkg-config --cflags sdl 2>&1) and folds it into the
# library compile flags. When 'sdl' (SDL 1.x) is absent the pkg-config error
# text — including a stray backtick from `sdl.pc' — pollutes CFLAGS and breaks
# the shell. Override SDL_CFLAGS empty for the lib build.
pkg_build() { run make -j "$MJOBS" libquirc.a SDL_CFLAGS=; }

pkg_install() {
  install -d "$PREFIX/include" "$PREFIX/lib" "$PREFIX/lib/pkgconfig"
  install -m 0644 lib/quirc.h "$PREFIX/include/"
  install -m 0644 libquirc.a "$PREFIX/lib/"
  cat > "$PREFIX/lib/pkgconfig/libquirc.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: quirc
Description: QR decoding library
Version: $PKG_VERSION
Libs: -L\${libdir} -lquirc
Libs.private: -lm
Cflags: -I\${includedir}
EOF
}
