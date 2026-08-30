# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="dav1d"
PKG_VERSION="${PKG_VERSION_DAV1D:-1.5.3}"
# VideoLAN's release server, NOT code.videolan.org's generated archive
# (GH-69). A `/-/archive/<ref>/` tarball is computed on demand, which is why
# that host fronts it with Anubis bot protection -- intermittently serving a
# 7KB challenge page with HTTP 200, which reads as a successful download and
# fails checksum verification. Generated archives are also not a stable thing
# to pin: GitHub's 2023 codeload change invalidated every checksum recorded
# against one. This is a static release artifact on a plain file server.
PKG_URL="$(videolan_release_url dav1d "$PKG_VERSION")"
PKG_FFMPEG_OPT="--enable-libdav1d"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  _cflagsbackup="$CFLAGS"
  if [ "$OS_MACOS_ARM" = true ]; then
    # APPEND, never replace. This used to assign CFLAGS="-arch arm64" outright,
    # which on macOS ARM threw away the operator's flags, the -O2 default,
    # -fPIC, and -- the part that is a plain bug rather than a policy question --
    # mediaforge's own -I$PREFIX/include, so the build lost the prefix's headers
    # on exactly the platform this branch exists to support.
    export CFLAGS="$CFLAGS -arch arm64"
  fi
  rm -rf build && mkdir -p build
  # FFmpeg links libdav1d.a; it never invokes dav1d's CLI. Building the tools
  # cost compile time and installed a ~3MB $PREFIX/bin/dav1d that nothing in
  # this project or downstream of it uses.
  #
  # It also breaks any build below -O2. The tools include the SYSTEM
  # /usr/include/xxhash.h, whose XXH3_*_sse2 helpers are __attribute__
  # ((always_inline)); at -Og gcc declines to inline them and hard-errors
  # ("inlining failed in call to always_inline"). Measured: the library alone
  # configures and builds clean at -Og once the tools are off. Leaving them on
  # would make dav1d the one recipe that cannot be built for debugging.
  mf_meson build -Denable_tools=false -Denable_tests=false
  if [ "$OS_MACOS_ARM" = true ]; then
    export CFLAGS="$_cflagsbackup"
  fi
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
