PKG_NAME="rav1e"
PKG_VERSION="0.8.1"
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
  execute cargo cinstall --prefix="$WORKSPACE" --libdir=lib \
    --library-type=staticlib --crt-static --release
}
