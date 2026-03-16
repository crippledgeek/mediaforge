PKG_NAME="nv-codec"
PKG_VERSION="${PKG_VERSION_NV_CODEC:-11.1.5.3}"
PKG_GITHUB_REPO="FFmpeg/nv-codec-headers"
PKG_URL="https://github.com/FFmpeg/nv-codec-headers/releases/download/n${PKG_VERSION}/nv-codec-headers-${PKG_VERSION}.tar.gz"
PKG_LINUX_ONLY=true
PKG_REQUIRES_CMD="nvcc"

pkg_configure() {
  :
}

pkg_build() {
  execute make PREFIX="$WORKSPACE"
}

pkg_install() {
  execute make PREFIX="$WORKSPACE" install
}

pkg_post_install() {
  printf '%s\n' "-I/usr/local/cuda/include" >> "$WORKSPACE/.extra_cflags"
  printf '%s\n' "-L/usr/local/cuda/lib64" >> "$WORKSPACE/.extra_ldflags"

  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-cuda-nvcc --enable-cuvid --enable-nvdec --enable-nvenc --enable-cuda-llvm --enable-ffnvcodec"

  _cuda_cc="${CUDA_COMPUTE_CAPABILITY:-52}"
  NVCC_FLAGS="--nvccflags=-gencode arch=compute_${_cuda_cc},code=sm_${_cuda_cc} -O2"
}
