# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="harfbuzz"
PKG_VERSION="${PKG_VERSION_HARFBUZZ:-10.4.0}"
PKG_GITHUB_REPO="harfbuzz/harfbuzz"
PKG_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${PKG_VERSION}/harfbuzz-${PKG_VERSION}.tar.xz"
PKG_REQUIRES_MESON=true
# drawtext text shaping. --enable-libharfbuzz has existed since FFmpeg 6.1,
# so it applies to all supported profiles (no version gate).
PKG_FFMPEG_OPT="--enable-libharfbuzz"
# Transitive utility — drops both harfbuzz.pc and harfbuzz-subset.pc.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="harfbuzz harfbuzz-subset"

pkg_configure() {
  rm -rf build && mkdir -p build
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
