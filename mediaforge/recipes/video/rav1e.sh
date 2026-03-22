PKG_NAME="rav1e"
PKG_VERSION="${PKG_VERSION_RAV1E:-0.8.1}"
PKG_GITHUB_REPO="xiph/rav1e"
PKG_URL="https://github.com/xiph/rav1e/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librav1e"
PKG_REQUIRES_CMD="cargo"

if [ "$SKIPRAV1E" = "yes" ]; then
  PKG_DISABLED=true
fi

pkg_prepare() {
  log "If you get 'requires rustc x.xx or newer', try 'rustup update'"
  execute cargo install cargo-c
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
  execute cargo cinstall --prefix="$PREFIX" --libdir=lib \
    --library-type=cdylib --release
}
