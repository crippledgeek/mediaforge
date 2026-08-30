# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="opencl"
PKG_VERSION="${PKG_VERSION_OPENCL:-2025.07.22}"
PKG_GITHUB_REPO="KhronosGroup/OpenCL-Headers"
PKG_URL="https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="OpenCL-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-opencl"
PKG_LINUX_ONLY=true

pkg_configure() {
  mf_cmake -B build/
}

pkg_build() {
  # Headers only -- there is nothing to compile, so the build phase is a no-op
  # and the install moved to pkg_install where it belongs (GH-59). It used to
  # run `cmake --build build --target install` here, which installed from the
  # BUILD phase: outside the staging window, so the 18 CL headers reached the
  # prefix unrecorded and this recipe reported `unverifiable` for a reason that
  # was the framework's rather than its own.
  :
}

pkg_install() {
  # The headers first, and LIVE before the sub-build below configures against
  # them with -DCMAKE_PREFIX_PATH="$PREFIX". mf_stage_claim publishes them and
  # takes them for this recipe's own stamp, out of reach of the nested
  # stamp_write that follows -- the same rule recipes/audio/lv2.sh follows.
  run cmake --build build --target install
  mf_stage_claim

  if stamp_check "opencl-icd-loader" "$PKG_VERSION"; then
    fetch "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/v${PKG_VERSION}.tar.gz" \
      "OpenCL-ICD-Loader-${PKG_VERSION}.tar.gz"
    mf_cmake -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -B build/
    run cmake --build build --target install
    stamp_write "opencl-icd-loader" "$PKG_VERSION"
  fi
}
