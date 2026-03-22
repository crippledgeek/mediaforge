PKG_NAME="opencl"
PKG_VERSION="${PKG_VERSION_OPENCL:-2025.07.22}"
PKG_GITHUB_REPO="KhronosGroup/OpenCL-Headers"
PKG_URL="https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="OpenCL-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-opencl"
PKG_LINUX_ONLY=true

pkg_configure() {
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -B build/
}

pkg_build() {
  run cmake --build build --target install
}

pkg_install() {
  if stamp_check "opencl-icd-loader" "$PKG_VERSION"; then
    fetch "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/v${PKG_VERSION}.tar.gz" \
      "OpenCL-ICD-Loader-${PKG_VERSION}.tar.gz"
    run cmake -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -B build/
    run cmake --build build --target install
    stamp_write "opencl-icd-loader" "$PKG_VERSION"
  fi
}
