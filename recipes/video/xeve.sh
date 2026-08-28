# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# EVC main profile is patent-encumbered; baseline is royalty-free. Software BSD-3-Clause.
PKG_NAME="xeve"
PKG_VERSION="${PKG_VERSION_LIBXEVE:-0.5.1}"
PKG_GITHUB_REPO="mpeg5/xeve"
PKG_URL="https://github.com/mpeg5/xeve/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="xeve-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"

# --enable-libxeve requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libxeve"
else
  PKG_DISABLED=true
fi

# Built from a tarball (no .git), xeve's CMakeLists can't `git describe` its
# version and aborts unless version.txt exists in the source root, in the
# format v[MAJOR].[MINOR].[PATCH]. Write it before configure.
pkg_prepare() {
  printf 'v%s\n' "$PKG_VERSION" > "$DISTDIR/xeve-${PKG_VERSION}/version.txt"

  # MEMORY SAFETY: xeve sizes its picture buffers from param->codec_bit_depth but
  # always writes 16-bit pels, so an 8-bit codec depth overflows every plane.
  # FFmpeg forwards arbitrary -xeve-params straight into xeve_param_parse(), so
  # `-xeve-params codec-bit-depth=8` corrupts the heap in the binary we ship;
  # upstream's own v0.5.1 xeve_app segfaults on the documented
  # --codec-bit-depth 8 too. The patch rejects anything outside the supported
  # {10, 12}. Full rationale in the patch header.
  #
  # Applied with the strict ffmpeg.sh idiom, NOT the lenient `|| true` used by
  # some recipes: a security patch that silently stops applying after a version
  # bump is exactly the failure this must not have.
  if ! patch -p1 -f --fuzz=0 < "$SCRIPT_DIR/patches/xeve-codec-bit-depth-overflow.patch"; then
    patch -p1 -R --fuzz=0 --dry-run < "$SCRIPT_DIR/patches/xeve-codec-bit-depth-overflow.patch" >/dev/null 2>&1 \
      || die "xeve-codec-bit-depth-overflow.patch failed to apply and is not already applied"
  fi
}

# xeve requires an out-of-source build/ dir. Default (no SET_PROF) builds the
# MAIN profile (which also supports baseline). xeve ignores BUILD_SHARED_LIBS and
# unconditionally builds BOTH a static (src_main/libxeve.a) and a shared lib;
# its install rules put the shared lib flat in lib/ but the static archive in a
# nested lib/xeve/ subdir. pkg_install corrects that (see below).
pkg_configure() {
  _src="$DISTDIR/xeve-${PKG_VERSION}"
  rm -rf "$_src/build"
  mkdir -p "$_src/build"
  cd "$_src/build" || die "Failed to cd to xeve build dir"
  mf_cmake -DBUILD_SHARED_LIBS=OFF ..
}

pkg_build() {
  cd "$DISTDIR/xeve-${PKG_VERSION}/build" || die "Failed to cd to xeve build dir"
  default_build
}

pkg_install() {
  cd "$DISTDIR/xeve-${PKG_VERSION}/build" || die "Failed to cd to xeve build dir"
  default_install
  # This is a static build, but upstream's install ships the shared lib and
  # puts the static archive in a nested lib/xeve/ subdir that mediaforge's
  # installer (flat lib/*.a glob) never copies. Install a flat libxeve.a so
  # FFmpeg's --static link of -lxeve resolves it, drop the shared lib, and
  # remove the redundant nested archive so it doesn't linger in the workspace.
  cp src_main/libxeve.a "$PREFIX/lib/libxeve.a" \
    || die "xeve static lib (src_main/libxeve.a) not found"
  rm -f "$PREFIX/lib/libxeve.so" "$PREFIX/lib/libxeve.so".*
  rm -rf "$PREFIX/lib/xeve"
}

# xeve is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/xeve.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
