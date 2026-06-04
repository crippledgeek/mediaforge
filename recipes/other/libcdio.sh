# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# CD audio input. GPL-3.0+ (binary resolves to GPLv3 when linked). Requires
# libcdio-paranoia (built as sub-package).
PKG_NAME="libcdio"
PKG_VERSION="${PKG_VERSION_LIBCDIO:-2.3.0}"
PKG_GITHUB_REPO="libcdio/libcdio"
PKG_URL="https://github.com/libcdio/libcdio/releases/download/${PKG_VERSION}/libcdio-${PKG_VERSION}.tar.bz2"
PKG_FILENAME="libcdio-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-libcdio"
PKG_GPL=true

# Autotools. default_configure appends $PKG_CONFIGURE_FLAGS after
# --prefix --disable-shared --enable-static. Drop all CLI sample programs;
# FFmpeg only needs the libraries + pkgconfig.
PKG_CONFIGURE_FLAGS="--without-cd-drive --without-cd-info --without-cdda-player --without-cd-read --without-iso-info --without-iso-read --disable-example-progs"

# FFmpeg's --enable-libcdio probes pkg-config libcdio_paranoia and links
# -lcdio_paranoia -lcdio_cdda -lcdio. libcdio-paranoia is a separate upstream
# project (rocky/libcdio-paranoia); build it here against the just-installed
# libcdio. It installs libcdio_paranoia.pc + libcdio_cdda.pc. mediaforge's
# PKG_CONFIG_PATH already includes $PREFIX/lib/pkgconfig, so its configure
# resolves the freshly-installed libcdio.
pkg_post_install() {
  _saved=$(pwd)
  _para_ver="${PKG_VERSION_LIBCDIO_PARANOIA:-10.2+2.0.2}"
  if stamp_check "libcdio-paranoia" "$_para_ver"; then
    fetch "https://github.com/rocky/libcdio-paranoia/releases/download/release-${_para_ver}/libcdio-paranoia-${_para_ver}.tar.bz2"
    cd "$DISTDIR/libcdio-paranoia-${_para_ver}" || die "Failed to cd to libcdio-paranoia source"
    run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
      --disable-cpp-progs --disable-example-progs
    run make -j "$MJOBS"
    run make install
    stamp_write "libcdio-paranoia" "$_para_ver"
  fi
  cd "$_saved" || die "restore dir after libcdio-paranoia"
}
