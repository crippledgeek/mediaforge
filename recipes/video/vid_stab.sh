PKG_NAME="vid_stab"
PKG_VERSION="${PKG_VERSION_VID_STAB:-1.1.1}"
PKG_GITHUB_REPO="georgmartius/vid.stab"
PKG_URL="https://github.com/georgmartius/vid.stab/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="vid.stab-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvidstab"
PKG_GPL=true
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DUSE_OMP=OFF -DENABLE_SHARED=off"

pkg_prepare() {
  if [ "$OS_MACOS_ARM" = true ]; then
    curl -L -sS -o fix_cmake_quoting.patch \
      "https://raw.githubusercontent.com/Homebrew/formula-patches/5bf1a0e0cfe666ee410305cece9c9c755641bfdf/libvidstab/fix_cmake_quoting.patch"
    patch -p1 < fix_cmake_quoting.patch
  fi
}
