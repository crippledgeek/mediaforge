# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# APV designed royalty-free (Samsung). BSD-3-Clause.
PKG_NAME="oapv"
PKG_VERSION="${PKG_VERSION_LIBOAPV:-0.2.1.3}"
PKG_GITHUB_REPO="AcademySoftwareFoundation/openapv"
PKG_URL="https://github.com/AcademySoftwareFoundation/openapv/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openapv-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# --enable-liboapv requires FFmpeg >= 8.0.
if ffmpeg_version_ge 8.0; then
  PKG_FFMPEG_OPT="--enable-liboapv"
else
  PKG_DISABLED=true
fi

# Static library only; no apps, no shared lib, no tests. openapv supports
# in-source builds (no CMAKE_BINARY_DIR guard), so the framework default
# `cmake ... .` is fine.
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="\
  -DOAPV_BUILD_APPS=OFF \
  -DOAPV_BUILD_SHARED_LIB=OFF \
  -DOAPV_BUILD_STATIC_LIB=ON \
  -DENABLE_TESTS=OFF"

# openapv's CMake installs the static archive into <prefix>/lib/oapv (a subdir;
# src/CMakeLists.txt) and its oapv.pc points Libs.private at <prefix>/lib/oapv.
# mediaforge's installer only copies lib/*.a (flat), so liboapv.a never reaches
# the installed prefix and FFmpeg's libavcodec.pc inherits a dangling
# -L<prefix>/lib/oapv (downstream static link fails: "library not found: oapv").
# The patch installs the archive to <prefix>/lib like every other codec and
# points the generated .pc at ${libdir}.
# --fuzz=0: require exact context. A future openapv bump that drifts the patched
# lines should fail loudly here (→ update the patch), not silently mis-apply at a
# fuzzy offset and leave liboapv.a / oapv.pc wrong.
pkg_prepare() {
  if ! patch -p1 -f --fuzz=0 < "$SCRIPT_DIR/patches/oapv-install-libdir.patch"; then
    patch -p1 -R --fuzz=0 --dry-run < "$SCRIPT_DIR/patches/oapv-install-libdir.patch" >/dev/null 2>&1 \
      || die "oapv-install-libdir.patch failed to apply and is not already applied"
  fi
}
