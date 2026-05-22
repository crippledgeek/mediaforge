# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="speex"
PKG_VERSION="${PKG_VERSION_SPEEX:-1.2.1}"
PKG_GITHUB_REPO="xiph/speex"
PKG_URL="https://downloads.xiph.org/releases/speex/speex-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libspeex"
