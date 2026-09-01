# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="librist"
PKG_VERSION="${PKG_VERSION_LIBRIST:-0.2.11}"
PKG_GITHUB_REPO="xiph/librist"
# Pinned by COMMIT and fetched over git (GH-69). librist has no presence on
# download.videolan.org at all, and its "releases" are GitLab tags -- which
# resolve to the same generated `/-/archive/` tarballs that host fronts with
# Anubis bot protection, serving a challenge page as HTTP 200.
#
# The commit below is what refs/tags/v0.2.11 PEELS TO -- `refs/tags/v0.2.11^{}`
# in ls-remote output, not the refs/tags/v0.2.11 line above it, which names the
# annotated tag OBJECT. Pinning the tag object here is what broke the first
# build of this recipe: it is 40 hex, it fetches, and checkout then peels it
# anyway and lands on a SHA the pin never named. Re-resolve with
# `git ls-remote <url> 'v<x>^{}'` when bumping the version.
#
# No .hash sidecar: the pinned commit is the integrity check, as for x264,
# libplacebo, av1 and librtmp. fetch_git requires a full object name.
PKG_COMMIT="${PKG_COMMIT_LIBRIST:-c526858020ce14c1ef156c0c68a655ba8dfe8b00}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
# Declared because pkg_prepare shells out to git; check_guards then reports a
# missing git against this package rather than letting the clone fail mid-phase.
PKG_REQUIRES_CMD="git"
PKG_FFMPEG_OPT="--enable-librist"
PKG_REQUIRES_MESON=true

pkg_prepare() {
  fetch_git https://code.videolan.org/rist/librist.git "$DISTDIR/librist" "$PKG_COMMIT"
  cd "$DISTDIR/librist" || die "Failed to cd to librist"
  # librist 0.2.11 uses -pedantic-errors, which promotes -Wdiscarded-qualifiers
  # to a hard error on GCC 15. Sits here rather than above pkg_prepare, where it
  # read as a description of the whole function: it explains these two lines and
  # nothing else in the phase.
  CFLAGS="$CFLAGS -Wno-error=discarded-qualifiers"
  export CFLAGS
}

pkg_configure() {
  mf_reset_dir build
  mf_meson build \
    -Dbuilt_tools=false -Dtest=false
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
}
