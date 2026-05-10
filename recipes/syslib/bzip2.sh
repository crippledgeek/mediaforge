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
  run make -j "$MJOBS" CFLAGS="-Wall -Winline -O2 -g -D_FILE_OFFSET_BITS=64 -fPIC" libbz2.a
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
