# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# Netflix VMAF perceptual quality metric. BSD+Patent.
PKG_NAME="vmaf"
PKG_VERSION="${PKG_VERSION_LIBVMAF:-3.1.0}"
PKG_GITHUB_REPO="Netflix/vmaf"
PKG_URL="https://github.com/Netflix/vmaf/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="vmaf-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvmaf"
PKG_REQUIRES_MESON=true

# The meson project lives in the libvmaf/ subdir of the tarball. Every path is
# relative to the tarball root (where fetch leaves cwd) so the configure/build/
# install phases stay cwd-consistent — the framework does not reset cwd between
# phases.
pkg_configure() {
  rm -rf libvmaf/build
  run meson setup libvmaf/build libvmaf --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Denable_tests=false -Denable_docs=false -Denable_tools=false \
    -Dbuilt_in_models=true
}

pkg_build() {
  run ninja -C libvmaf/build
}

pkg_install() {
  run ninja -C libvmaf/build install
}

# libvmaf is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/libvmaf.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
