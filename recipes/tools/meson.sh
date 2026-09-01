# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# meson — build-system generator used by ~13 recipes (dav1d, harfbuzz,
# fontconfig, libplacebo, ...). meson is pure Python and ships a runnable
# meson.py alongside its mesonbuild/ package, so we vendor that tree under
# $PREFIX/share/meson and drop a launcher in $PREFIX/bin (ordered before any
# meson consumer) — the host's meson is never used. python3 stays a host
# prerequisite (vendoring a Python interpreter is out of scope); PKG_REQUIRES_CMD
# makes a missing python3 a loud, early failure. Apache-2.0.
PKG_NAME="meson"
PKG_VERSION="${PKG_VERSION_MESON:-1.11.1}"
PKG_GITHUB_REPO="mesonbuild/meson"
PKG_URL="https://github.com/mesonbuild/meson/releases/download/${PKG_VERSION}/meson-${PKG_VERSION}.tar.gz"
PKG_FILENAME="meson-${PKG_VERSION}.tar.gz"
PKG_REQUIRES_CMD="python3"

# Pure Python: nothing to configure or compile.
pkg_configure() { default_noop; }
pkg_build()     { default_noop; }

# _dest is where this phase writes (the stage, GH-68) and _live is where the
# tree ends up. Both are needed because the launcher below has to name the path
# meson will actually be run from, and DESTDIR must never reach file contents.
# The rm aims at _live for the same reason it always did: the merge only adds,
# so a mesonbuild/ that shed a module upstream would keep it here forever.
pkg_install() {
  _src="$DISTDIR/meson-${PKG_VERSION}"
  _live="$PREFIX/share/meson"
  _dest="$(mf_dest_prefix)/share/meson"
  _bin="$(mf_dest_prefix)/bin/meson"
  mf_remove_tree "$_live"
  mf_dest_mkdir share/meson bin
  cp -R "$_src/meson.py" "$_src/mesonbuild" "$_dest/" \
    || die "Failed to install meson package tree to $_dest"
  # Launcher: meson.py locates its mesonbuild/ package relative to itself, so a
  # thin python3 shim is all that's needed. $PREFIX is fixed for a build and
  # meson is build-time-only (never shipped to the install prefix), so the
  # absolute path here is stable.
  {
    printf '#!/bin/sh\n'
    printf 'exec python3 "%s/meson.py" "$@"\n' "$_live"
  } > "$_bin"
  chmod +x "$_bin"
}
