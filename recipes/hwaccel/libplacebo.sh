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
  # Reuse an existing clone if present (same idiom as librtmp.sh). A clone that
  # failed partway would leave a stale dir; remove $DISTDIR/libplacebo to re-clone.
  if [ ! -d "$DISTDIR/libplacebo" ]; then
    run git clone --recursive --depth 1 --branch "v${PKG_VERSION}" \
      https://code.videolan.org/videolan/libplacebo.git "$DISTDIR/libplacebo"
  fi
  cd "$DISTDIR/libplacebo" || die "Failed to cd to libplacebo"
}

pkg_configure() {
  # Follow the --spirv= selector so only one glslang copy lands in the final
  # binary. glslang/shaderc are meson 'feature' options (enabled/disabled/auto);
  # vulkan is also a feature; demos/tests are 'boolean' (true/false). Verified
  # against meson_options.txt @ v7.360.1.
  if [ "${SPIRV_IMPL:-glslang}" = shaderc ]; then
    _spv="-Dshaderc=enabled -Dglslang=disabled"
  else
    _spv="-Dglslang=enabled -Dshaderc=disabled"
  fi
  rm -rf build && mkdir -p build
  # shellcheck disable=SC2086
  run meson setup build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib" \
    -Dvulkan=enabled -Ddemos=false -Dtests=false $_spv
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
