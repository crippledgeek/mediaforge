# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# Transitive utility — fribidi.pc not installed (system has it).
PKG_TRANSITIVE_UTIL=true
PKG_NAME="fribidi"
PKG_VERSION="${PKG_VERSION_FRIBIDI:-1.0.16}"
PKG_GITHUB_REPO="fribidi/fribidi"
PKG_URL="https://github.com/fribidi/fribidi/releases/download/v${PKG_VERSION}/fribidi-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfribidi"
PKG_REQUIRES_MESON=true

pkg_configure() {
  mf_reset_dir build
  mf_meson build \
    -Ddocs=false -Dtests=false
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
