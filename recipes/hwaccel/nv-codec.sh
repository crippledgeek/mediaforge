PKG_NAME="nv-codec"
PKG_VERSION="${PKG_VERSION_NV_CODEC:-11.1.5.3}"
PKG_GITHUB_REPO="FFmpeg/nv-codec-headers"
PKG_URL="https://github.com/FFmpeg/nv-codec-headers/releases/download/n${PKG_VERSION}/nv-codec-headers-${PKG_VERSION}.tar.gz"
PKG_LINUX_ONLY=true
# No PKG_REQUIRES_CMD — nv-codec-headers is headers-only, no CUDA toolkit needed

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
  # NVENC/NVDEC/CUVID work with headers + runtime driver only
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-cuvid --enable-nvdec --enable-nvenc --enable-ffnvcodec"

  # Full CUDA compiler support (scale_npp, cuda filters) requires nvcc
  if command_exists nvcc; then
    _cuda_home="${CUDA_HOME:-}"
    if [ -z "$_cuda_home" ]; then
      for _d in /opt/cuda /usr/local/cuda; do
        if [ -d "$_d" ]; then _cuda_home="$_d"; break; fi
      done
    fi
    if [ -n "$_cuda_home" ]; then
      printf '%s\n' "-I$_cuda_home/include" >> "$WORKSPACE/.extra_cflags"
      printf '%s\n' "-L$_cuda_home/lib64" >> "$WORKSPACE/.extra_ldflags"
    fi
    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-cuda-nvcc --enable-cuda-llvm"
    _cuda_cc="${CUDA_COMPUTE_CAPABILITY:-52}"
    NVCC_FLAGS="--nvccflags=-gencode arch=compute_${_cuda_cc},code=sm_${_cuda_cc} -O2"
  fi
}
