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
  # build ~108 recipes at -O0 -g3 and this one fully optimized -- the "reaches
  # three of the knobs" failure at recipe granularity, and silent because it
  # still links.
  #
  # Precisely what was wrong: rav1e's manifest already sets debug = true, so the
  # un-patched build did emit symbols; the gaps were the optimization level and
  # lto = "thin", which --debug promises to force off. DEBUG=2 therefore pins
  # what the manifest happens to give today rather than adding something absent.
  #
  # openssl needs no such handling despite also having its own configure: it
  # reads CFLAGS from the environment and places it LAST
  # (LIB_CFLAGS=-fPIC $(CNF_CFLAGS) $(CFLAGS)), so the level already reaches it.
  # Verified by configuring it with -O0 -g3 and reading the generated makefile.
  #
  # The mapping itself lives in lib/flags.sh with the rest of the level table --
  # it is level knowledge, not recipe knowledge. Held in a plain variable and
  # applied to the cargo command in pkg_install rather than EXPORTED here: an
  # export would outlive this recipe, since pkg_configure runs in the main shell
  # and the framework's save/restore covers only CFLAGS and friends. Unsetting it
  # at the end of this function is NOT the alternative -- cargo does not run
  # until pkg_install, so that would drop the setting before its only consumer.
  _rav1e_cargo_env=$(mf_debug_cargo_env "${MF_DEBUG_LEVEL:-}")
  [ -n "$_rav1e_cargo_env" ] && log "rav1e: cargo overrides $_rav1e_cargo_env"
}

pkg_build() {
  :
}

pkg_install() {
  # Build as shared library (cdylib) to avoid embedding Rust's std/alloc/gimli
  # symbols into a static .a — those cause duplicate symbol errors when any
  # other Rust project links against this FFmpeg build
  # The cargo overrides are scoped to THIS command via an env prefix, so nothing
  # is left in the environment for the recipes that run after this one.
  # Unquoted by design: the value is one of three fixed strings from the level
  # table, selected by a level mediaforge.sh has already validated, so it can
  # hold no glob and no unexpected word. Empty when no level is active, in which
  # case the expansion vanishes and the command is exactly what it always was.
  # shellcheck disable=SC2086
  run ${_rav1e_cargo_env:+env $_rav1e_cargo_env} cargo cinstall --prefix="$PREFIX" --libdir=lib \
    --library-type=cdylib --release
}
