# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AVS2 — AVS patent pool (devices charged; software free). GPL-2.0.
PKG_NAME="xavs2"
PKG_VERSION="${PKG_VERSION_LIBXAVS2:-1.4}"
PKG_GITHUB_REPO="pkuvcl/xavs2"
PKG_URL="https://github.com/pkuvcl/xavs2/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="xavs2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxavs2"
PKG_GPL=true

# x264-style build under build/linux. The framework does NOT reset cwd between
# phases, so each phase cds to the absolute build dir (idempotent). The Makefile
# has no plain `install` target — install-lib-static installs libxavs2.a, the
# headers, and xavs2.pc (which FFmpeg's --enable-libxavs2 probes).
# xavs2 1.4 (2019) predates GCC 14, which promoted incompatible-pointer-types
# (and friends) from warnings to hard errors by default. Demote them back via
# --extra-cflags so the old C compiles on GCC 14/15/16.
_xavs2_compat="-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=implicit-int"
pkg_configure() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run ./configure --prefix="$PREFIX" --disable-cli \
    --disable-shared --enable-static --enable-pic \
    --extra-cflags="$_xavs2_compat"
}

pkg_build() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run make -j "$MJOBS"
}

pkg_install() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run make install-lib-static
}
