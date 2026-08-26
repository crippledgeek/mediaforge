# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="vid_stab"
PKG_VERSION="${PKG_VERSION_VID_STAB:-1.1.1}"
PKG_GITHUB_REPO="georgmartius/vid.stab"
PKG_URL="https://github.com/georgmartius/vid.stab/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="vid.stab-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvidstab"
PKG_GPL=true
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DUSE_OMP=OFF -DENABLE_SHARED=off"

# Routed through fetch() rather than a raw curl so the patch is verified
# against vid_stab.hash like every other fetched file. The old call had neither
# -f nor a digest, so an HTTP error page was written under the patch's name and
# fed straight to `patch -p1`. fetch() verifies before its *patch* early
# return, and leaves the file in $DISTDIR rather than the source tree.
pkg_prepare() {
  if [ "$OS_MACOS_ARM" = true ]; then
    fetch "https://raw.githubusercontent.com/Homebrew/formula-patches/5bf1a0e0cfe666ee410305cece9c9c755641bfdf/libvidstab/fix_cmake_quoting.patch" \
      "vid_stab-fix_cmake_quoting.patch"
    patch -p1 < "$DISTDIR/vid_stab-fix_cmake_quoting.patch"
  fi
}
