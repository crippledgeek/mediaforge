PKG_NAME="vulkan-headers"
PKG_VERSION="${PKG_VERSION_VULKAN_HEADERS:-1.4.338}"
PKG_GITHUB_REPO="KhronosGroup/Vulkan-Headers"
PKG_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="Vulkan-Headers-${PKG_VERSION}.tar.gz"
# Vulkan loader (libvulkan) ships .so only on Arch — no static lib. Headers
# install fine at compile time, but FFmpeg's static link of --enable-vulkan
# needs libvulkan.a, which doesn't exist. Decided at source-time so
# stamp-cache hits also see the override.
if [ -n "$LDEXEFLAGS" ]; then
  log "Skipping --enable-vulkan (incompatible with --enable-static — libvulkan.a not available)"
  PKG_FFMPEG_OPT=""
else
  PKG_FFMPEG_OPT="--enable-vulkan"
fi

pkg_configure() {
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -B build/
}

pkg_build() {
  :
}

pkg_install() {
  run cmake --install build --prefix "$PREFIX"
}
