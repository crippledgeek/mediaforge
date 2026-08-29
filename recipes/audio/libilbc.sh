# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libilbc"
PKG_VERSION="${PKG_VERSION_LIBILBC:-3.0.4}"
PKG_GITHUB_REPO="TimothyGu/libilbc"
PKG_URL="https://github.com/TimothyGu/libilbc/releases/download/v${PKG_VERSION}/libilbc-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libilbc-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libilbc"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS=""

# Upstream ASSIGNS CMAKE_C_FLAGS rather than appending, which replaces the value
# cmake initialises from the environment -- so the composed CFLAGS never reached
# the compile line and a --debug=full build compiled with "-Wall ... -g
# -fvisibility=hidden" and nothing of mediaforge's. The archive got DWARF 2 from
# cmake's own Debug -g rather than the -g3 the level asks for.
#
# A patch rather than a -D on the cmake line, because a plain set() in a
# CMakeLists creates a NORMAL variable that shadows the cache entry a
# -DCMAKE_C_FLAGS_DEBUG would write: the flag would be accepted and ignored.
pkg_prepare() {
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/libilbc-cmake-append-flags.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/libilbc-cmake-append-flags.patch" >/dev/null 2>&1 \
      || die "libilbc-cmake-append-flags.patch failed to apply and is not already applied"
  fi
}
