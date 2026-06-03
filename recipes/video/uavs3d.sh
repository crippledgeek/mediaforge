# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AVS3 — AVS patent pool (devices charged; software/internet free). BSD-3-Clause.
PKG_NAME="uavs3d"
PKG_VERSION="${PKG_VERSION_LIBUAVS3D:-v1.1}"
PKG_GITHUB_REPO="uavs3/uavs3d"
PKG_URL="https://github.com/uavs3/uavs3d/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="uavs3d-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libuavs3d"
PKG_CMAKE=true

# uavs3d's CMake calls version.sh (needs git + gawk) via execute_process to
# generate version.h. Building from a tarball has no .git, so version.sh
# silently fails and version.h is never written — which leaves the .pc Version
# field blank but does not block the lib/header install FFmpeg needs. We write
# a minimal version.h fallback so the build is deterministic and the .pc Version
# is populated. Upstream layout: out-of-source build under build/linux.
pkg_prepare() {
  _src="$DISTDIR/uavs3d-${PKG_VERSION}"
  if [ ! -f "$_src/version.h" ]; then
    {
      printf '#ifndef __VERSION_H__\n'
      printf '#define __VERSION_H__\n'
      printf '#define VER_MAJOR 1\n'
      printf '#define VER_MINOR 1\n'
      printf '#define VER_BUILD 0\n'
      printf '#define VERSION_TYPE "release"\n'
      printf '#define VERSION_STR "1.1.0"\n'
      printf '#define VERSION_SHA1 ""\n'
      printf '#endif // __VERSION_H__\n'
    } > "$_src/version.h"
  fi
}

pkg_configure() {
  _src="$DISTDIR/uavs3d-${PKG_VERSION}"
  rm -rf "$_src/build/linux"
  mkdir -p "$_src/build/linux"
  cd "$_src/build/linux" || die "Failed to cd to uavs3d build dir"
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release ../..
}

pkg_build() {
  cd "$DISTDIR/uavs3d-${PKG_VERSION}/build/linux" || die "Failed to cd to uavs3d build dir"
  default_build
}

pkg_install() {
  cd "$DISTDIR/uavs3d-${PKG_VERSION}/build/linux" || die "Failed to cd to uavs3d build dir"
  default_install
}
