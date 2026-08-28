# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# Transitive utility — bzip2.pc not installed (system has it).
PKG_TRANSITIVE_UTIL=true
PKG_NAME="bzip2"
PKG_VERSION="${PKG_VERSION_BZIP2:-1.0.8}"
PKG_URL="https://sourceware.org/pub/bzip2/bzip2-${PKG_VERSION}.tar.gz"
PKG_FILENAME="bzip2-${PKG_VERSION}.tar.gz"

# bzip2 ships a plain Makefile, no configure. We build only the static
# library (libbz2.a) and headers — skip the bzip2 CLI and shared object.
pkg_configure() {
  :
}

pkg_build() {
  # CFLAGS has to be passed on the make COMMAND LINE, not exported: bzip2's
  # Makefile assigns its own CFLAGS, and a make command-line variable is the
  # only thing that outranks that assignment.
  #
  # It must be DERIVED from the composed line rather than replacing it, which is
  # what it used to do. The old literal was
  #   "-Wall -Winline -O2 -g -D_FILE_OFFSET_BITS=64 -fPIC"
  # and because a command-line variable outranks the environment, it discarded
  # the operator's CFLAGS, mediaforge's include path, and the -O2 default alike.
  # Its hardcoded "-g" is also why libbz2.a was the ONLY archive in
  # workspace/lib carrying DWARF -- an accident, not a decision.
  #
  # What stays local is what is genuinely bzip2's: its two warning flags and
  # _FILE_OFFSET_BITS=64 (upstream's BIGFILES). -O2 and -fPIC are dropped
  # because the composed line already carries both.
  run make -j "$MJOBS" \
    CFLAGS="$CFLAGS -Wall -Winline -D_FILE_OFFSET_BITS=64" libbz2.a
}

pkg_install() {
  install -d "$PREFIX/include" "$PREFIX/lib"
  install -m 0644 bzlib.h "$PREFIX/include/"
  install -m 0644 libbz2.a "$PREFIX/lib/"
}

# bzip2 ships no .pc file. Provide a minimal one so consumers (libpng,
# freetype) that use `pkg-config --static --libs bzip2` find -lbz2.
pkg_post_install() {
  cat > "$PREFIX/lib/pkgconfig/bzip2.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: bzip2
Description: Burrows-Wheeler block-sorting compression library
Version: $PKG_VERSION
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
}
