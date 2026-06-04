# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AVS3 — AVS patent pool (devices charged; software/internet free). BSD-3-Clause.
#
# Pinned to a master commit, NOT the v1.1 tag. FFmpeg's libuavs3d.c wrapper
# (every version 6.1..8.0) reads seqh->colour_primaries/transfer_characteristics/
# matrix_coefficients, which the v1.1 tag never exposed on com_seqh_t — the bits
# are parsed and discarded in v1.1's parser.c. Commit 6eb2109 ("Add sequence
# display extensions to support HDR", 2020-08-15, post-v1.1) added those fields
# to com_seqh_t and made parser.c store them, so the wrapper compiles unpatched
# AND gains HDR colour-metadata propagation. Upstream never cut a tag after v1.1
# (internal version bumped to 1.2 but untagged), so a commit SHA is the only way
# to get this fix. master HEAD as of 2026-06-04; public decode API
# (uavs3d_io_frm_t, uavs3d_create/decode/flush/…) is byte-identical to v1.1.
# NOTE: `check-updates` will report v1.1 as "latest" (it queries tags/releases);
# that is expected — we deliberately track master past the last tag.
PKG_NAME="uavs3d"
PKG_VERSION="${PKG_VERSION_LIBUAVS3D:-0e20d2c291853f196c68922a264bcd8471d75b68}"
PKG_GITHUB_REPO="uavs3/uavs3d"
# /archive/<ref>.tar.gz resolves a branch, tag, or full commit SHA alike.
PKG_URL="https://github.com/uavs3/uavs3d/archive/${PKG_VERSION}.tar.gz"
PKG_FILENAME="uavs3d-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libuavs3d"
PKG_CMAKE=true

# uavs3d's CMake calls version.sh (needs git + gawk) via execute_process to
# generate version.h. Building from a tarball has no .git, so version.sh
# silently fails and version.h is never written — which leaves the .pc Version
# field blank but does not block the lib/header install FFmpeg needs. We write
# a minimal version.h fallback so the build is deterministic and the .pc Version
# is populated. Values mirror master's version.sh defaults (major 1, minor 2).
# Upstream layout: out-of-source build under build/linux.
pkg_prepare() {
  _src="$DISTDIR/uavs3d-${PKG_VERSION}"
  if [ ! -f "$_src/version.h" ]; then
    {
      printf '#ifndef __VERSION_H__\n'
      printf '#define __VERSION_H__\n'
      printf '#define VER_MAJOR 1\n'
      printf '#define VER_MINOR 2\n'
      printf '#define VER_BUILD 0\n'
      printf '#define VERSION_TYPE "release"\n'
      printf '#define VERSION_STR "1.2.0"\n'
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
  # uavs3d's CMakeLists declares cmake_minimum_required(VERSION 3.1). That is
  # rejected by CMake 4.x, but mediaforge builds its own cmake 3.31.7 ahead of
  # every cmake consumer (recipes/_order.conf) and puts it first on PATH, so the
  # host's cmake version is irrelevant here.
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
