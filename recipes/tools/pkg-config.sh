PKG_NAME="pkg-config"
PKG_VERSION="${PKG_VERSION_PKG_CONFIG:-0.29.2}"
PKG_URL="https://pkgconfig.freedesktop.org/releases/pkg-config-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS="--silent --with-pc-path=$WORKSPACE/lib/pkgconfig --with-internal-glib"

pkg_prepare() {
  sed 's/gboolean bool;/gboolean bool_val;/g' glib/glib/goption.c > glib/glib/goption.c.tmp \
    && mv glib/glib/goption.c.tmp glib/glib/goption.c
  sed 's/change->prev\.bool/change->prev.bool_val/g' glib/glib/goption.c > glib/glib/goption.c.tmp \
    && mv glib/glib/goption.c.tmp glib/glib/goption.c

  if [ "$IS_DARWIN" = true ]; then
    CFLAGS="$CFLAGS -Wno-int-conversion -Wno-error=int-conversion"
    export CFLAGS
  fi
}
