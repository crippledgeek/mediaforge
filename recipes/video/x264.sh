# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="x264"
PKG_VERSION="${PKG_VERSION_X264:-0480cb05}"
# Pinned by COMMIT and fetched over git, not as a generated GitLab archive
# (GH-69). x264 publishes no release tarball for a commit -- the only static
# tarballs on download.videolan.org are dated snapshots that stop in 2019 -- so
# `/-/archive/<sha>/` was the only tarball URL available, and that endpoint is
# Anubis-fronted: it intermittently returns a 7KB challenge page with HTTP 200,
# which reads as a successful download and then fails checksum verification
# mid-build.
#
# Measured on the same host at the same moment: `git ls-remote` succeeded while
# the archive endpoint returned the challenge. Git smart-HTTP is a different
# request shape and is what Anubis's default policy is built to leave alone.
#
# The integrity model changes with it: no .hash sidecar, because the pinned
# commit IS the integrity check. That is how libplacebo, av1 and librtmp already
# work here. fetch_git rejects an abbreviated SHA or a tag, so the pin below
# must stay a full object name.
PKG_COMMIT="${PKG_COMMIT_X264:-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
# Declared because pkg_prepare shells out to git; check_guards then reports a
# missing git against this package rather than letting the clone fail mid-phase.
PKG_REQUIRES_CMD="git"
PKG_FFMPEG_OPT="--enable-libx264"
PKG_GPL=true
PKG_MUTEX_GROUP="h264"

pkg_prepare() {
  fetch_git https://code.videolan.org/videolan/x264.git "$DISTDIR/x264" "$PKG_COMMIT"
  cd "$DISTDIR/x264" || die "Failed to cd to x264"
}

pkg_configure() {
  if [ "$OS_LINUX" = true ]; then
    run ./configure --prefix="$PREFIX" --enable-static --enable-pic \
      CXXFLAGS="-fPIC $CXXFLAGS"
  else
    run ./configure --prefix="$PREFIX" --enable-static --enable-pic
  fi
}

pkg_post_install() {
  run make install-lib-static
}
