PKG_NAME="vulkan-headers"
PKG_VERSION="${PKG_VERSION_VULKAN_HEADERS:-1.4.338}"
PKG_GITHUB_REPO="KhronosGroup/Vulkan-Headers"
PKG_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="Vulkan-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vulkan"

pkg_configure() {
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -B build/
}

pkg_build() {
  :
}

pkg_install() {
  run cmake --install build --prefix "$PREFIX"
}
