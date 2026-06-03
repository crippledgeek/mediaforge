# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# LC3 royalty-free per Bluetooth SIG. Apache-2.0.
PKG_NAME="lc3"
PKG_VERSION="${PKG_VERSION_LIBLC3:-1.1.3}"
PKG_GITHUB_REPO="google/liblc3"
PKG_URL="https://github.com/google/liblc3/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="liblc3-${PKG_VERSION}.tar.gz"
PKG_REQUIRES_MESON=true

# --enable-liblc3 requires FFmpeg >= 7.1.
if ffmpeg_version_ge 7.1; then
  PKG_FFMPEG_OPT="--enable-liblc3"
else
  PKG_DISABLED=true
fi

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Dtools=false -Dpython=false
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
