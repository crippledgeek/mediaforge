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

# --enable-liblcevc-dec requires FFmpeg >= 7.1 (FFmpeg probes pkg-config
# lcevc_dec, installed from cmake/templates/lcevc_dec.pc.in).
if ffmpeg_version_ge 7.1; then
  PKG_FFMPEG_OPT="--enable-liblcevc-dec"
else
  PKG_DISABLED=true
fi

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
  rm -rf build
  run cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DVN_SDK_EXECUTABLES=OFF -DVN_SDK_UNIT_TESTS=OFF \
    -DVN_SDK_SAMPLE_SOURCE=OFF -DVN_SDK_JSON_CONFIG=OFF \
    -DVN_SDK_PIPELINE_VULKAN=OFF -DVN_SDK_DOCS=OFF \
    -DVN_SDK_SYSTEM_INSTALL=OFF
}

pkg_build() { run cmake --build build -j "$MJOBS"; }

pkg_install() { run cmake --install build; }
