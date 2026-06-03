# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# GPL. DVD navigation. Depends on libdvdread (built earlier in _order.conf);
# mediaforge already exports PKG_CONFIG_PATH including $PREFIX/lib/pkgconfig, so
# dvdnav's configure resolves the freshly-installed dvdread.pc. CSS decryption
# is inherited from dvdread, which mediaforge builds without libdvdcss.
PKG_NAME="libdvdnav"
PKG_VERSION="${PKG_VERSION_LIBDVDNAV:-7.0.0}"
PKG_URL="https://code.videolan.org/videolan/libdvdnav/-/archive/${PKG_VERSION}/libdvdnav-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libdvdnav-${PKG_VERSION}.tar.gz"
PKG_GPL=true

# --enable-libdvdnav requires FFmpeg >= 7.0 (FFmpeg probes pkg-config dvdnav).
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libdvdnav"
else
  PKG_DISABLED=true
fi

# Build-system split by version (verified against upstream tags):
#   7.0.x tags ship meson.build  -> meson/ninja. No libdvdcss option (CSS is
#     pulled transitively through dvdread).
#   6.1.x tags ship configure.ac + m4/ but NO configure / autogen.sh / bootstrap
#     -> regenerate the autotools build with `autoreconf -fiv`, then configure.
pkg_prepare() {
  if [ ! -f meson.build ] && [ ! -x ./configure ]; then
    run autoreconf -fiv
  fi
}

pkg_configure() {
  if [ -f meson.build ]; then
    rm -rf build && mkdir -p build
    run meson setup build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
  else
    run ./configure --prefix="$PREFIX" --disable-shared --enable-static
  fi
}

pkg_build() {
  if [ -f meson.build ]; then
    run ninja -C build
  else
    run make -j "$MJOBS"
  fi
}

pkg_install() {
  if [ -f meson.build ]; then
    run ninja -C build install
  else
    run make install
  fi
}
