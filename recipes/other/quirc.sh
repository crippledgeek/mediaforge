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

# quirc's Makefile sets SDL_CFLAGS := $(shell pkg-config --cflags sdl 2>&1) and
# folds it into the library compile flags. The 2>&1 captures pkg-config's error
# text — including a stray backtick from `sdl.pc' — into CFLAGS when SDL 1.x is
# absent, which breaks the shell during compilation. The patch changes it to
# 2>/dev/null so an absent SDL yields empty flags. (The library needs no SDL.)
pkg_prepare() {
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/quirc-sdl-cflags.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/quirc-sdl-cflags.patch" >/dev/null 2>&1 \
      || die "quirc-sdl-cflags.patch failed to apply and is not already applied"
  fi
}

pkg_configure() { :; }

# quirc folds $(CFLAGS) into QUIRC_CFLAGS with `?=`, so the environment already
# wins here -- verified by building it with -O0 -g3 in the environment and
# reading DW_AT_producer off libquirc.a. Passed on the command line anyway,
# because `?=` is one upstream character away from the plain assignment that
# made giflib build stripped under --debug, and a command-line macro survives
# that flip. -Ilib is upstream's and is added after this, so it is not lost.
pkg_build() { run make -j "$MJOBS" CFLAGS="-Wall $CFLAGS" libquirc.a; }

# The files go to mf_dest_prefix, not $PREFIX -- a shell install(1) writes past
# the stage (GH-68) -- while the .pc's own prefix= line keeps naming the REAL
# $PREFIX, because DESTDIR must never reach file contents.
pkg_install() {
  _dest=$(mf_dest_prefix)
  mf_dest_mkdir include lib lib/pkgconfig
  install -m 0644 lib/quirc.h "$_dest/include/"
  install -m 0644 libquirc.a "$_dest/lib/"
  cat > "$_dest/lib/pkgconfig/libquirc.pc" <<EOF
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
