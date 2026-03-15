PKG_NAME="opencl"
PKG_VERSION="2025.07.22"
PKG_URL="https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="OpenCL-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-opencl"
PKG_LINUX_ONLY=true

pkg_configure() {
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -B build/
}

pkg_build() {
  execute cmake --build build --target install
}

pkg_install() {
  if build "opencl-icd-loader" "$PKG_VERSION"; then
    download "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/v${PKG_VERSION}.tar.gz" \
      "OpenCL-ICD-Loader-${PKG_VERSION}.tar.gz"
    execute cmake -DCMAKE_PREFIX_PATH="$WORKSPACE" -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -B build/
    execute cmake --build build --target install
    build_done "opencl-icd-loader" "$PKG_VERSION"
  fi
}
