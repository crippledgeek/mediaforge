# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="glslang"
PKG_VERSION="${PKG_VERSION_GLSLANG:-16.1.0}"
PKG_GITHUB_REPO="KhronosGroup/glslang"
PKG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="glslang-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libglslang"
PKG_MUTEX_GROUP="spirv"
PKG_REQUIRES_CMD="python3"
PKG_CMAKE_BUILD_TYPE="Release"

pkg_prepare() {
  run ./update_glslang_sources.py
}

pkg_configure() {
  mf_cmake -DENABLE_SHARED=OFF \
    -DBUILD_SHARED_LIBS=OFF .
}
