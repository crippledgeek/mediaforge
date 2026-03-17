PKG_NAME="libass"
PKG_VERSION="${PKG_VERSION_LIBASS:-0.17.3}"
PKG_GITHUB_REPO="libass/libass"
PKG_URL="https://github.com/libass/libass/releases/download/${PKG_VERSION}/libass-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libass"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-require-system-font-provider
}
