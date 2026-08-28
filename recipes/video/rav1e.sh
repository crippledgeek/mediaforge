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

  # rav1e is the one recipe the composed CFLAGS cannot reach: cargo compiles
  # Rust, and Rust does not read CFLAGS at all. Left alone, `--debug=full` would
  # build ~108 recipes at -O0 -g3 and this one fully optimized with no symbols --
  # the "reaches three of the four knobs" failure at recipe granularity, and
  # silent because it still links.
  #
  # openssl needs no such handling despite also having its own configure: it
  # reads CFLAGS from the environment and places it LAST
  # (LIB_CFLAGS=-fPIC $(CNF_CFLAGS) $(CFLAGS)), so the level already reaches it.
  # Verified by configuring it with -O0 -g3 and reading the generated makefile.
  #
  # The translation lives here rather than in the shared table because it is
  # cargo's vocabulary, not the tree's: cargo has no -Og, so `balanced` maps to
  # opt-level=1, the closest thing it offers. Kept in the RELEASE profile, which
  # is what `cargo cinstall --release` below builds, so only these two knobs move.
  if [ -n "${MF_DEBUG_LEVEL:-}" ]; then
    export CARGO_PROFILE_RELEASE_DEBUG=2
    case "$(mf_debug_opt "$MF_DEBUG_LEVEL")" in
      -O0) export CARGO_PROFILE_RELEASE_OPT_LEVEL=0 ;;
      -Og) export CARGO_PROFILE_RELEASE_OPT_LEVEL=1 ;;
      *)   export CARGO_PROFILE_RELEASE_OPT_LEVEL=2 ;;
    esac
    log "rav1e: cargo release profile at opt-level=$CARGO_PROFILE_RELEASE_OPT_LEVEL with debug info"
  fi
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
