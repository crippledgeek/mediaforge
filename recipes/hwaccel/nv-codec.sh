PKG_NAME="nv-codec"
PKG_VERSION="${PKG_VERSION_NV_CODEC:-11.1.5.3}"
PKG_GITHUB_REPO="FFmpeg/nv-codec-headers"
PKG_URL="https://github.com/FFmpeg/nv-codec-headers/releases/download/n${PKG_VERSION}/nv-codec-headers-${PKG_VERSION}.tar.gz"
PKG_LINUX_ONLY=true
# nv-codec-headers is headers-only, no CUDA toolkit needed for NVENC/NVDEC.
# CUDA-compiled filters (scale_cuda, yadif_cuda, …) need nvcc + a compute
# capability the toolkit still supports.
PKG_FFMPEG_OPT="--enable-cuvid --enable-nvdec --enable-nvenc --enable-ffnvcodec"

pkg_configure() {
  :
}

pkg_build() {
  run make PREFIX="$PREFIX"
}

pkg_install() {
  run make PREFIX="$PREFIX" install
}

pkg_post_install() {
  # NVENC/NVDEC/CUVID flags ship via PKG_FFMPEG_OPT (above) so they are
  # accumulated even when the recipe is stamp-cached. Below we add the
  # CUDA-compiled-filter flags only when nvcc both exists AND can target
  # the GPU's compute capability.
  command_exists nvcc || return 0

  _cuda_home="${CUDA_HOME:-}"
  if [ -z "$_cuda_home" ]; then
    for _d in /opt/cuda /usr/local/cuda; do
      if [ -d "$_d" ]; then _cuda_home="$_d"; break; fi
    done
  fi

  # Resolve compute capability: explicit env var > nvidia-smi probe of the
  # actual GPU > the toolkit's own lowest supported arch (best practice — adapts
  # to whatever CUDA major is installed) > 75 (Turing — CUDA 13 minimum).
  _cuda_cc="${CUDA_COMPUTE_CAPABILITY:-}"
  if [ -z "$_cuda_cc" ] && command_exists nvidia-smi; then
    _cuda_cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
  fi
  if [ -z "$_cuda_cc" ]; then
    # `nvcc --list-gpu-arch` emits e.g. "compute_75\ncompute_80\n..." (lowest
    # first). Available since CUDA 11.6.
    _cuda_cc=$(nvcc --list-gpu-arch 2>/dev/null | head -1 | sed 's/^compute_//')
  fi
  _cuda_cc="${_cuda_cc:-75}"

  # Probe: does this nvcc still support the chosen compute cap? Generates a
  # tiny .cu and tries to compile it. CUDA 13 dropped Pascal/Volta (≤sm_70).
  _probe_dir=$(mktemp -d)
  printf '__global__ void _mf_probe(){}\n' > "$_probe_dir/probe.cu"
  if ! nvcc -arch="compute_${_cuda_cc}" -ptx -o "$_probe_dir/probe.ptx" \
       "$_probe_dir/probe.cu" >/dev/null 2>&1; then
    rm -rf "$_probe_dir"
    warn "nvcc rejects compute_${_cuda_cc} (CUDA toolkit too new for this GPU?)"
    warn "Skipping --enable-cuda-nvcc / --enable-cuda-llvm — NVENC/NVDEC still active."
    warn "Workaround: install a CUDA toolkit ≤12.x for this GPU, or set"
    warn "CUDA_COMPUTE_CAPABILITY=75 (or higher supported value) and rebuild."
    return 0
  fi
  rm -rf "$_probe_dir"

  if [ -n "$_cuda_home" ]; then
    printf '%s\n' "-I$_cuda_home/include" >> "$PREFIX/.extra_cflags"
    printf '%s\n' "-L$_cuda_home/lib64" >> "$PREFIX/.extra_ldflags"
  fi
  FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-cuda-nvcc --enable-cuda-llvm"
  NVCCFLAGS="-gencode arch=compute_${_cuda_cc},code=sm_${_cuda_cc} -O2"
}
