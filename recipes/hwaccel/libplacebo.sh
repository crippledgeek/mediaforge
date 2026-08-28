# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# libplacebo — GPU-accelerated video/image post-processing (FFmpeg vf_libplacebo).
#
# Canonical source is the VideoLAN GitLab. It carries 6 git submodules
# (glad, jinja, markupsafe, Vulkan-Headers, fast_float, nuklear), several of
# which are build-critical: glad generates the Vulkan loader; jinja/markupsafe
# generate the embedded shaders. A release tarball does NOT vendor these (and
# the github.com/haasn mirror ships empty submodule placeholders), so a plain
# fetch+extract is broken — clone recursively instead (PKG_SKIP_EXTRACT + git),
# mirroring recipes/other/librtmp.sh.
PKG_NAME="libplacebo"
PKG_VERSION="${PKG_VERSION_LIBPLACEBO:-7.360.1}"
# Pinned by COMMIT rather than by the v7.360.1 tag: a tag is a mutable
# server-side pointer, so pinning one authenticates nothing. This is the object
# v7.360.1 named on 2026-08-24. The commit also pins the six submodules, since
# it records their SHAs.
PKG_COMMIT="${PKG_COMMIT_LIBPLACEBO:-cee9b076f2c63104ccfd497fa79c39a867293ec4}"
PKG_URL=""                       # cloned (recursive) — mirror has empty submodules
PKG_SKIP_EXTRACT=true
PKG_REQUIRES_CMD="git python3"
PKG_REQUIRES_MESON=true

# libplacebo's Vulkan GPU filters need libvulkan, which has no static lib on Arch.
# Under a full static build, skip the whole (heavy) build — not just the flag like
# vulkan-headers.sh does for its header-only install. Decided at source time so
# stamp-cache hits also see the override.
if [ -n "$LDEXEFLAGS" ]; then
  log "Skipping libplacebo (Vulkan GPU processing incompatible with --enable-static — libvulkan.a unavailable)"
  PKG_FFMPEG_OPT=""
  PKG_DISABLED=true
else
  PKG_FFMPEG_OPT="--enable-libplacebo"
fi

pkg_prepare() {
  # Same helper as librtmp.sh: fetch the pinned commit, reusing an existing tree
  # only when it is already AT that commit. The old form reused $DISTDIR/libplacebo
  # whenever the directory merely existed, so a clone left behind by an
  # interrupted run, or by a different pin, was compiled without complaint.
  fetch_git https://code.videolan.org/videolan/libplacebo.git \
    "$DISTDIR/libplacebo" "$PKG_COMMIT"
  cd "$DISTDIR/libplacebo" || die "Failed to cd to libplacebo"
  # fetch_git deliberately does not do submodules — librtmp has none. The six
  # here are pinned by the commit above, so this inherits its guarantee.
  run git submodule update --init --recursive --depth 1
  # libplacebo is a C library but statically embeds glslang (C++); its
  # meson-generated .pc omits the C++ runtime, so FFmpeg's static link probe
  # fails with undefined std::locale / C++ symbols. Patch pkg.generate() to add
  # -lstdc++ to Libs.private (at the source, so the generated .pc is correct).
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/libplacebo-pc-cxx-runtime.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/libplacebo-pc-cxx-runtime.patch" >/dev/null 2>&1 \
      || die "libplacebo-pc-cxx-runtime.patch failed to apply and is not already applied"
  fi
}

pkg_configure() {
  # Follow the --spirv= selector so only one glslang copy lands in the final
  # binary. glslang/shaderc are meson 'feature' options (enabled/disabled/auto);
  # vulkan is also a feature; demos/tests are 'boolean' (true/false). Verified
  # against meson_options.txt @ v7.360.1.
  if [ "${SPIRV_IMPL:-glslang}" = shaderc ]; then
    _spv_a="-Dshaderc=enabled"; _spv_b="-Dglslang=disabled"
  else
    _spv_a="-Dglslang=enabled"; _spv_b="-Dshaderc=disabled"
  fi
  rm -rf build && mkdir -p build
  mf_meson build \
    -Dvulkan=enabled -Ddemos=false -Dtests=false "$_spv_a" "$_spv_b"
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
