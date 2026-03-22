PKG_NAME="lv2"
PKG_VERSION="${PKG_VERSION_LV2:-1.18.10}"
PKG_URL="https://lv2plug.in/spec/lv2-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-lv2"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  run meson build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib"
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install

  _lv2_saved_dir=$(pwd)

  # waflib
  if stamp_check "waflib" "b600c92"; then
    fetch "https://gitlab.com/drobilla/autowaf/-/archive/b600c92/autowaf-b600c92.tar.gz" "autowaf.tar.gz"
    stamp_write "waflib" "b600c92"
  fi

  # serd
  if stamp_check "serd" "0.32.6"; then
    fetch "https://gitlab.com/drobilla/serd/-/archive/v0.32.6/serd-v0.32.6.tar.gz" "serd-v0.32.6.tar.gz"
    run meson build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    run ninja -C build
    run ninja -C build install
    stamp_write "serd" "0.32.6"
  fi

  # pcre
  if stamp_check "pcre" "8.45"; then
    fetch "https://altushost-swe.dl.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz" "pcre-8.45.tar.gz"
    run ./configure --prefix="$PREFIX" --disable-shared --enable-static
    run make -j "$MJOBS"
    run make install
    stamp_write "pcre" "8.45"
  fi

  # zix
  if stamp_check "zix" "0.8.0"; then
    fetch "https://gitlab.com/drobilla/zix/-/archive/v0.8.0/zix-v0.8.0.tar.gz" "zix-v0.8.0.tar.gz"
    run meson setup build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    cd build || die "Failed to cd to zix build"
    run meson configure -Dc_args="-march=native" -Dprefix="$PREFIX" -Dlibdir="$PREFIX/lib"
    run meson compile
    run meson install
    stamp_write "zix" "0.8.0"
  fi

  # sord
  if stamp_check "sord" "0.16.20"; then
    fetch "https://gitlab.com/drobilla/sord/-/archive/v0.16.20/sord-v0.16.20.tar.gz" "sord-v0.16.20.tar.gz"
    run meson build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    run ninja -C build
    run ninja -C build install
    stamp_write "sord" "0.16.20"
  fi

  # sratom
  if stamp_check "sratom" "0.6.20"; then
    fetch "https://gitlab.com/lv2/sratom/-/archive/v0.6.20/sratom-v0.6.20.tar.gz" "sratom-v0.6.20.tar.gz"
    run meson build --prefix="$PREFIX" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    run ninja -C build
    run ninja -C build install
    stamp_write "sratom" "0.6.20"
  fi

  # lilv
  if stamp_check "lilv" "0.26.2"; then
    fetch "https://gitlab.com/lv2/lilv/-/archive/v0.26.2/lilv-v0.26.2.tar.gz" "lilv-v0.26.2.tar.gz"
    run meson build --prefix="$PREFIX" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib" -Dcpp_std=c++11
    run ninja -C build
    run ninja -C build install
    stamp_write "lilv" "0.26.2"
  fi

  cd "$_lv2_saved_dir" || die "Failed to restore dir after lv2 sub-builds"
}

pkg_post_install() {
  printf '%s\n' "-I$PREFIX/include/lilv-0" >> "$PREFIX/.extra_cflags"
}
