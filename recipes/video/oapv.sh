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
PKG_CMAKE_FLAGS="\
  -DCMAKE_BUILD_TYPE=Release \
  -DOAPV_BUILD_APPS=OFF \
  -DOAPV_BUILD_SHARED_LIB=OFF \
  -DOAPV_BUILD_STATIC_LIB=ON \
  -DENABLE_TESTS=OFF"
