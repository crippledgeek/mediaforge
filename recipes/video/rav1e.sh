# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="rav1e"
PKG_VERSION="${PKG_VERSION_RAV1E:-0.8.1}"
PKG_GITHUB_REPO="xiph/rav1e"
# rav1e tags semver releases as v<ver> but the date pseudo-versions the 6.1/
# 7.0/7.1 profiles pin (e.g. p20231128) as bare <ver> -- probed live
# 2026-08-25: vp20231128 -> 404, p20231128 -> 200.
case "$PKG_VERSION" in
  p*) _tag="$PKG_VERSION" ;;
  *)  _tag="v${PKG_VERSION}" ;;
esac
PKG_URL="https://github.com/xiph/rav1e/archive/refs/tags/${_tag}.tar.gz"
PKG_FFMPEG_OPT="--enable-librav1e"
PKG_MUTEX_GROUP="av1-enc"
PKG_REQUIRES_CMD="cargo"

if [ "$SKIPRAV1E" = "yes" ]; then
  PKG_DISABLED=true
fi

pkg_prepare() {
  log "If you get 'requires rustc x.xx or newer', try 'rustup update'"
  run cargo install cargo-c
}

pkg_configure() {
  export RUSTFLAGS="-C target-cpu=native"
}

pkg_build() {
  :
}

pkg_install() {
  # Build as shared library (cdylib) to avoid embedding Rust's std/alloc/gimli
  # symbols into a static .a — those cause duplicate symbol errors when any
  # other Rust project links against this FFmpeg build
  run cargo cinstall --prefix="$PREFIX" --libdir=lib \
    --library-type=cdylib --release
}
