PKG_NAME="lv2"
PKG_VERSION="${PKG_VERSION_LV2:-1.18.10}"
PKG_URL="https://lv2plug.in/spec/lv2-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-lv2"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  execute meson build --prefix="$PREFIX" --buildtype=release \
    --default-library=static --libdir="$PREFIX/lib"
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install

  _lv2_saved_dir=$(pwd)

  # waflib
  if build "waflib" "b600c92"; then
    download "https://gitlab.com/drobilla/autowaf/-/archive/b600c92/autowaf-b600c92.tar.gz" "autowaf.tar.gz"
    build_done "waflib" "b600c92"
  fi

  # serd
  if build "serd" "0.32.6"; then
    download "https://gitlab.com/drobilla/serd/-/archive/v0.32.6/serd-v0.32.6.tar.gz" "serd-v0.32.6.tar.gz"
    execute meson build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "serd" "0.32.6"
  fi

  # pcre
  if build "pcre" "8.45"; then
    download "https://altushost-swe.dl.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz" "pcre-8.45.tar.gz"
    execute ./configure --prefix="$PREFIX" --disable-shared --enable-static
    execute make -j "$MJOBS"
    execute make install
    build_done "pcre" "8.45"
  fi

  # zix
  if build "zix" "0.8.0"; then
    download "https://gitlab.com/drobilla/zix/-/archive/v0.8.0/zix-v0.8.0.tar.gz" "zix-v0.8.0.tar.gz"
    execute meson setup build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    cd build || die "Failed to cd to zix build"
    execute meson configure -Dc_args="-march=native" -Dprefix="$PREFIX" -Dlibdir="$PREFIX/lib"
    execute meson compile
    execute meson install
    build_done "zix" "0.8.0"
  fi

  # sord
  if build "sord" "0.16.20"; then
    download "https://gitlab.com/drobilla/sord/-/archive/v0.16.20/sord-v0.16.20.tar.gz" "sord-v0.16.20.tar.gz"
    execute meson build --prefix="$PREFIX" --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "sord" "0.16.20"
  fi

  # sratom
  if build "sratom" "0.6.20"; then
    download "https://gitlab.com/lv2/sratom/-/archive/v0.6.20/sratom-v0.6.20.tar.gz" "sratom-v0.6.20.tar.gz"
    execute meson build --prefix="$PREFIX" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "sratom" "0.6.20"
  fi

  # lilv
  if build "lilv" "0.26.2"; then
    download "https://gitlab.com/lv2/lilv/-/archive/v0.26.2/lilv-v0.26.2.tar.gz" "lilv-v0.26.2.tar.gz"
    execute meson build --prefix="$PREFIX" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$PREFIX/lib" -Dcpp_std=c++11
    execute ninja -C build
    execute ninja -C build install
    build_done "lilv" "0.26.2"
  fi

  cd "$_lv2_saved_dir" || die "Failed to restore dir after lv2 sub-builds"
}

pkg_post_install() {
  printf '%s\n' "-I$PREFIX/include/lilv-0" >> "$PREFIX/.extra_cflags"
}
