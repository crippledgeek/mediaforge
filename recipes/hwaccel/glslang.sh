PKG_NAME="glslang"
PKG_VERSION="16.1.0"
PKG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="glslang-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libglslang"
PKG_REQUIRES_CMD="python3"

pkg_prepare() {
  execute ./update_glslang_sources.py
}

pkg_configure() {
  execute cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$WORKSPACE" .
}
