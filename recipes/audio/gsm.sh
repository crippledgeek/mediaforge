# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="gsm"
PKG_VERSION="${PKG_VERSION_GSM:-1.0.22}"
PKG_URL="https://www.quut.com/gsm/gsm-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libgsm"

# gsm has old C code incompatible with C23 (GCC 15+ defaults to -std=gnu23)
PKG_C_STD="gnu11"

pkg_configure() {
  :
}

pkg_build() {
  run make -j "$MJOBS" INSTALL_ROOT="$PREFIX" \
    CC="gcc" CCFLAGS="$CFLAGS -c -DNeedFunctionPrototypes=1 -Wall -fPIC"
}

# mf_dest_prefix, not $PREFIX: gsm's Makefile has an install target, but this
# recipe never runs it, and a shell cp writes past the stage (GH-68).
pkg_install() {
  _dest=$(mf_dest_prefix)
  mf_dest_mkdir include/gsm lib
  cp inc/gsm.h "$_dest/include/gsm/"
  cp lib/libgsm.a "$_dest/lib/"
}
