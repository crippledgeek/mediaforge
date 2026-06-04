# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# Bundled so the host cmake is never used (see lib/platform.sh for the policy
# floor that lets this 4.x cmake build the frozen pre-3.5 codec sources).
PKG_NAME="cmake"
PKG_VERSION="${PKG_VERSION_CMAKE:-4.3.3}"
PKG_GITHUB_REPO="Kitware/CMake"
PKG_URL="https://github.com/Kitware/CMake/releases/download/v${PKG_VERSION}/cmake-${PKG_VERSION}.tar.gz"

pkg_configure() {
  # Don't pin -std: cmake 4.x's bootstrap auto-detects and prefers C++17
  # (its CMakeLists falls back to 14/11 only if 17 is unavailable). Forcing
  # -std=c++11 — correct for the old 3.x bundle — would break the 4.x build.
  run ./configure --prefix="$PREFIX" --parallel="$MJOBS" -- -DCMAKE_USE_OPENSSL=OFF
}
