# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# LCEVC patented by V-Nova; device deployment needs a patent license.
# Software BSD-3-Clause-Clear (free tier — not GPL).
PKG_NAME="lcevc"
PKG_VERSION="${PKG_VERSION_LIBLCEVC_DEC:-4.1.0}"
PKG_GITHUB_REPO="v-novaltd/LCEVCdec"
PKG_URL="https://github.com/v-novaltd/LCEVCdec/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="lcevc-dec-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# LCEVC is OPT-IN (build with --enable=lcevc). Three reasons it is default-off:
#   1. V-Nova patent encumbrance (device deployment needs a license).
#   2. Decode-only and niche — most consumers (e.g. rdlp) never use it.
#   3. It ships as 8 mutually-referencing static archives whose circular
#      references break a downstream single-pass static link unless merged
#      (see pkg_post_install). Keeping it off by default keeps the common
#      static FFmpeg build clean for consumers that don't use LCEVC.
PKG_DISABLED=true
# Linux-only for now: the archive merge in pkg_post_install uses GNU ar/ranlib.
# macOS (libtool -static) and Windows (lib.exe) branches are not wired up yet.
PKG_LINUX_ONLY=true
PKG_CMAKE_BUILD_TYPE="Release"

# --enable-liblcevc-dec requires FFmpeg >= 7.1 (FFmpeg probes pkg-config
# lcevc_dec, installed from cmake/templates/lcevc_dec.pc.in). Only accumulate
# the flag on >= 7.1; on older FFmpeg the lib still builds when force-enabled
# but FFmpeg is not told about it (harmless).
if ffmpeg_version_ge 7.1; then
  PKG_FFMPEG_OPT="--enable-liblcevc-dec"
fi

# Rewrite the generated lcevc_dec.pc to reference the single merged archive
# (-llcevc_dec) instead of the 7 split component archives. The patch edits the
# CMake .pc generator at source (auditable) rather than sed-ing the output.
pkg_prepare() {
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/lcevc-pc-merged-archive.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/lcevc-pc-merged-archive.patch" >/dev/null 2>&1 \
      || die "lcevc-pc-merged-archive.patch failed to apply and is not already applied"
  fi
}

# V-Nova's CMake pulls third-party deps (nlohmann-json, fmt, gtest, range-v3,
# ffmpeg) via Conan ONLY when executables/tests/json-config/base-decoder are
# enabled. With those OFF (and Vulkan off), conanfile.py's requirements() list
# is empty, so the core CPU-pipeline decoder + API layer build with no external
# packages. We disable every optional surface to keep the build self-contained:
#   VN_SDK_EXECUTABLES / VN_SDK_UNIT_TESTS / VN_SDK_SAMPLE_SOURCE — no samples/tests
#   VN_SDK_JSON_CONFIG — avoids nlohmann-json dependency
#   VN_SDK_PIPELINE_VULKAN — off (default); avoids vulkan-loader
#   VN_SDK_DOCS — off; VN_SDK_SYSTEM_INSTALL=OFF keeps licences inside $PREFIX
# LCEVCdec forbids in-source builds (cmake/modules/CMakeSetup.cmake) — use an
# out-of-source build/ dir.
pkg_configure() {
  mf_reset_dir build
  mf_cmake -S . -B build -DBUILD_SHARED_LIBS=OFF \
    -DVN_SDK_EXECUTABLES=OFF -DVN_SDK_UNIT_TESTS=OFF \
    -DVN_SDK_SAMPLE_SOURCE=OFF -DVN_SDK_JSON_CONFIG=OFF \
    -DVN_SDK_PIPELINE_VULKAN=OFF -DVN_SDK_DOCS=OFF \
    -DVN_SDK_SYSTEM_INSTALL=OFF
}

pkg_build() { run cmake --build build -j "$MJOBS"; }

pkg_install() { run cmake --install build; }

# Merge V-Nova's split static archives (liblcevc_dec_api.a, _api_utility.a,
# _common.a, _enhancement.a, _extract.a, _pipeline.a, _pipeline_cpu.a,
# _pixel_processing.a) into a single liblcevc_dec.a. A merged archive lets a
# downstream single-pass static link resolve the archives' circular references
# (GNU ld re-scans members WITHIN one archive until no new symbol is satisfied),
# which the 8 separate archives in a fixed pkg-config order cannot guarantee —
# the failure rdlp hit (undefined LCEVC_GetPictureDesc / LCEVC_*). The .pc was
# rewritten to -llcevc_dec by patches/lcevc-pc-merged-archive.patch.
#
# Linux-only (GNU ar/ranlib); PKG_LINUX_ONLY gates the whole recipe so this is
# unreachable on macOS/Windows until those toolchains are wired up.
pkg_post_install() {
  # Guard against an unset PREFIX before any glob/rm below operates on $_libdir
  # (the framework validates PREFIX at startup; this is defense-in-depth).
  [ -n "$PREFIX" ] || die "lcevc: PREFIX is unset"
  # _libdir is the LIVE prefix, which is where the split archives are: pkg_install
  # staged them and the claim before this phase merged them. _merged is the STAGE,
  # because `ar cr` CREATES a file and a create in the live prefix is past the
  # stage -- it would leave the one library FFmpeg links (-llcevc_dec) out of the
  # manifest, inside a stamp reading `verified`, while the eight archives it
  # replaces are recorded and then deleted below (GH-68).
  _libdir="$PREFIX/lib"
  mf_dest_mkdir lib
  _merged="$(mf_dest_prefix)/lib/liblcevc_dec.a"
  _work=$(mktemp -d)
  _idx=0
  # Extract each archive into its own subdir: object names collide across
  # archives (picture_layout.cpp.o is in both _api_utility.a and _pipeline.a),
  # so a flat `ar x` would silently clobber members.
  for _a in "$_libdir"/liblcevc_dec_*.a; do
    [ -f "$_a" ] || continue
    mkdir -p "$_work/$_idx"
    ( cd "$_work/$_idx" && run ar x "$_a" )
    _idx=$((_idx + 1))
  done
  [ "$_idx" -gt 0 ] || die "lcevc: no split archives found to merge in $_libdir"
  # Flatten with a per-archive index prefix so colliding object names coexist.
  for _sub in "$_work"/*/; do
    for _o in "$_sub"*.o; do
      [ -f "$_o" ] || continue
      mv "$_o" "$_work/$(basename "$_sub")_$(basename "$_o")"
    done
  done
  # Both names, because the two live in different trees now: the stale merged
  # archive to be replaced is in the live prefix, while $_merged is the stage.
  rm -f "$_merged" "$_libdir/liblcevc_dec.a"
  # `--` terminates ar option processing so a crafted upstream member name
  # beginning with '-' can't be read as a flag. shellcheck disable: the *.o
  # glob must word-split into separate member arguments.
  # shellcheck disable=SC2086
  run ar cr "$_merged" -- "$_work"/*.o
  run ranlib "$_merged"
  mf_remove_temp "$_work"
  # Drop the split archives: the .pc and FFmpeg reference only -llcevc_dec now,
  # and leaving them would let a downstream pick the broken split set.
  rm -f "$_libdir"/liblcevc_dec_*.a
}
