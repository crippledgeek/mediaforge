# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="av1"
PKG_VERSION="${PKG_VERSION_AV1:-3.14.1}"
# Fetched through git at a pinned commit, not from gitiles' +archive endpoint:
# gitiles rebuilds that tarball per request and stamps the CURRENT time into the
# tar headers, so no digest can pin it (google/gitiles#217, open; #84, its closed
# duplicate; measured, two sha256s a second apart). fetch_git in lib/download.sh
# carries the rest of the reasoning.
#
# THE PIN IS DELIBERATELY NOT CONTEMPORARY. The recipe default and all four
# profiles pin the SAME commit, v3.14.1, rather than the libaom that was
# current when each FFmpeg shipped, which is the rule those profiles otherwise
# follow (see each profile's own header line). Every contemporary candidate
# predates the fix for CVE-2026-56208, a heap overflow in the encoder's
# Look-Ahead Processing path that FFmpeg reaches by DEFAULT: it applies
# g_lag_in_frames only when the lag-in-frames AVOption is >= 0, and the option
# defaults to -1, so libaom's own non-zero default stands (FFmpeg 8.0's
# libaomenc.c:757-758; the same guard sits at 716-717 in 7.1 and 731-732 in 6.1).
#
# The fix is commit 243f8ae84b, "Handle buffer pointer in LAP mode to avoid
# overflow" (2026-04-29). v3.14.0 is the first release containing it. Note that
# the smaller-looking bump does NOT work: v3.13.3 was tagged 2026-04-01, before
# the fix, so the latest 3.13.x still ships the vulnerability.
#
# The sibling CVE-2026-56209/-56210 (SVC layer-id bounds) are fixed by the same
# release but are NOT reachable here. FFmpeg's libaomenc.c never calls
# AV1E_SET_SVC_LAYER_ID, verified in 6.1, 7.1 and 8.0. Recorded so a future
# reader does not cite them for a pin they do not actually motivate.
#
# Do not "restore" contemporaneity here without re-checking CVE-2026-56208.
PKG_COMMIT="${PKG_COMMIT_AV1:-03087864cf4bea6abb0d28f95cf7843511413d8f}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
PKG_REQUIRES_CMD="git"
PKG_FFMPEG_OPT="--enable-libaom"
PKG_MUTEX_GROUP="av1-enc"

pkg_prepare() {
  fetch_git https://aomedia.googlesource.com/aom "$DISTDIR/av1" "$PKG_COMMIT"
  cd "$DISTDIR/av1" || die "Failed to cd to $DISTDIR/av1"
}

pkg_configure() {
  rm -rf "$DISTDIR/aom_build" && mkdir -p "$DISTDIR/aom_build"
  cd "$DISTDIR/aom_build" || die "Failed to cd to aom_build"
  if [ "$OS_MACOS_ARM" = true ]; then
    run cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCONFIG_RUNTIME_CPU_DETECT=0 "$DISTDIR/av1"
  else
    run cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      "$DISTDIR/av1"
  fi
}
