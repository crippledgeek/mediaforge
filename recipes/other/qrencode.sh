# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# QR encoder. LGPL-2.1+.
PKG_NAME="qrencode"
PKG_VERSION="${PKG_VERSION_LIBQRENCODE:-4.1.1}"
PKG_GITHUB_REPO="fukuchi/libqrencode"
PKG_URL="https://github.com/fukuchi/libqrencode/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="qrencode-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# --enable-libqrencode requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libqrencode"
else
  PKG_DISABLED=true
fi

# Static library only; no tools, no tests. PNG is only used by the qrenc tool,
# so disable it to keep the library link minimal. Installs libqrencode.pc.
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="\
  -DWITH_TOOLS=NO \
  -DWITH_TESTS=NO \
  -DWITHOUT_PNG=YES"
