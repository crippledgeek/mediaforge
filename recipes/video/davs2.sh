# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AVS2 — AVS patent pool (devices charged; software free). GPL-2.0.
PKG_NAME="davs2"
PKG_VERSION="${PKG_VERSION_LIBDAVS2:-1.7}"
PKG_GITHUB_REPO="pkuvcl/davs2"
PKG_URL="https://github.com/pkuvcl/davs2/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="davs2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libdavs2"
PKG_GPL=true

# x264-style build under build/linux. Same cwd discipline as xavs2: cd to the
# absolute build dir per phase. davs2's configure builds static by default
# (no --enable-static flag; it offers --disable-static instead). install-lib-static
# installs libdavs2.a, headers, and davs2.pc (probed by --enable-libdavs2).
pkg_configure() {
  cd "$DISTDIR/davs2-${PKG_VERSION}/build/linux" || die "Failed to cd to davs2 build/linux"
  run ./configure --prefix="$PREFIX" --disable-cli \
    --disable-shared --enable-pic
}

pkg_build() {
  cd "$DISTDIR/davs2-${PKG_VERSION}/build/linux" || die "Failed to cd to davs2 build/linux"
  run make -j "$MJOBS"
}

pkg_install() {
  cd "$DISTDIR/davs2-${PKG_VERSION}/build/linux" || die "Failed to cd to davs2 build/linux"
  run make install-lib-static
}
