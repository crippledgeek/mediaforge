PKG_NAME="libshine"
PKG_VERSION="${PKG_VERSION_LIBSHINE:-3.1.1}"
PKG_URL="https://github.com/toots/shine/releases/download/${PKG_VERSION}/shine-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="toots/shine"
PKG_FFMPEG_OPT="--enable-libshine"

# libshine 3.1.1 has unprototyped functions incompatible with C23
# (empty parens mean void in C23, but functions take arguments)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
