# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="giflib"
PKG_VERSION="${PKG_VERSION_GIFLIB:-5.2.2}"
PKG_URL="https://sourceforge.net/projects/giflib/files/giflib-${PKG_VERSION}.tar.gz/download"
PKG_FILENAME="giflib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  cd "$DISTDIR/giflib-${PKG_VERSION}" || die "Failed to cd to giflib"
  patch -p1 < "$SCRIPT_DIR/patches/giflib-makefile.patch" 2>/dev/null || true
}

# giflib's Makefile ASSIGNS the compile flags -- `CFLAGS = ... $(OFLAGS)` with
# `OFLAGS = -O2` -- and a makefile assignment beats the environment; only a
# command-line macro overrides it (POSIX make, "Macros"). So the composed CFLAGS
# never reached this recipe: under --debug=full, libgif.a came out with no
# .debug_* sections at all, built at -O2 and stripped, while every sibling
# archive from the same run carried -O0 -g3. It compiled, linked and ran, so the
# only symptom was giflib frames missing from every backtrace.
#
# Passed on the command line rather than patched into the Makefile, matching what
# gsm, bzip2 and librtmp already do for the same upstream shape. The flags the
# library genuinely needs stay first and mediaforge's composed CFLAGS goes last,
# so its -O/-g -- and the operator's own -O after it -- win.
_giflib_cflags() { printf '%s' "-std=gnu99 -Wall -Wno-format-truncation $CFLAGS"; }

pkg_build() {
  run make CFLAGS="$(_giflib_cflags)"
}

# Same macro on the install run. Not because that run rebuilds anything today --
# `all` is the default goal and pkg_build already built it with these flags, so
# install finds everything up to date -- but because the two invocations must
# agree: a macro that depends on build order for its correctness is one
# reordering away from compiling half the library at the Makefile's -O2.
pkg_install() {
  run make PREFIX="$PREFIX" CFLAGS="$(_giflib_cflags)" install
}
