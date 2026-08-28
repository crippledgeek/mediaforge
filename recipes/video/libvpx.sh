# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libvpx"
PKG_VERSION="${PKG_VERSION_LIBVPX:-1.15.2}"
PKG_GITHUB_REPO="webmproject/libvpx"
PKG_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libvpx-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvpx"

pkg_prepare() {
  if [ "$OS_MACOS" = true ]; then
    log "Applying Darwin patch"
    sed "s/,--version-script//g" build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
    sed "s/-Wl,--no-undefined -Wl,-soname/-Wl,-undefined,error -Wl,-install_name/g" \
      build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
  fi
}

# libvpx compiles the symbols and then throws them away. Its own build rule is
#
#     HAVE_GNU_STRIP := $(if $(CONFIG_DEBUG),,$(HAVE_GNU_STRIP))
#     %.a: %_g.a      $(STRIP) --strip-debug -o $@ $<
#
# so the real archive is libvpx_g.a and the installed one is a stripped copy.
# Measured on a --debug=full build before this: libvpx_g.a 52.8 MB with 460
# .debug_info sections, the installed libvpx.a 4.9 MB with none. Everything the
# level asked for was built and then deleted.
#
# HAVE_GNU_STRIP=no on the make line is upstream's OWN escape -- the line above
# exists to trigger exactly this fallback, whose rule is a plain `cp`. A
# command-line macro is what makes it stick, since the Makefile assigns it.
#
# --enable-debug would also disable the strip, and it is deliberately NOT used
# for that: it additionally drops -DNDEBUG (configure.sh adds it in the non-debug
# branch), so it turns assertions on. At `symbols`, whose promise is no
# measurable cost, that is the wrong trade -- so the level is asked, through the
# table's assertions column, rather than each level being re-derived here.
# Two flags for two axes, and the first one is not optional.
#
# --disable-optimizations: vpx appends its OWN -O3 (configure.sh, "enabled small
# && check_add_cflags -O2 || check_add_cflags -O3"), and it lands after the
# composed CFLAGS, so last-wins hands it the decision. Measured after the strip
# was fixed and before this flag existed: the producer read "-g3 -g -O0 -O3",
# i.e. full symbols compiled at -O3 while --debug=full asks for -O0. Symbols
# without the optimization level is the half-fix that reads as working.
#
# --enable-debug: the assertions axis, and only where the level wants them. It
# is not used to keep the symbols -- HAVE_GNU_STRIP=no does that in pkg_build --
# because it also drops -DNDEBUG, which at `symbols` would turn assertions on at
# the one level promising no measurable cost.
_libvpx_debug_configure() {
  [ -n "${MF_DEBUG_LEVEL:-}" ] || return 0
  _vpx_opts='--disable-optimizations'
  if [ "$(mf_debug_assertions "$MF_DEBUG_LEVEL")" = on ]; then
    _vpx_opts="$_vpx_opts --enable-debug"
  fi
  printf '%s' "$_vpx_opts"
}

_libvpx_debug_make() {
  [ -n "${MF_DEBUG_LEVEL:-}" ] || return 0
  printf '%s' 'HAVE_GNU_STRIP=no'
}

pkg_configure() {
  # shellcheck disable=SC2046
  run ./configure --prefix="$PREFIX" --disable-unit-tests --disable-shared \
    --disable-examples --as=yasm --enable-vp9-highbitdepth \
    $(_libvpx_debug_configure)
}

pkg_build() {
  # shellcheck disable=SC2046
  run make -j "$MJOBS" $(_libvpx_debug_make)
}
