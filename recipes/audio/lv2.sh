# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="lv2"
PKG_VERSION="${PKG_VERSION_LV2:-1.18.10}"
PKG_URL="https://lv2plug.in/spec/lv2-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-lv2"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  mf_meson build
}

pkg_build() {
  run ninja -C build
}

pkg_install() {
  run ninja -C build install
  # Claim lv2's OWN files before any sub-package stamp is written (GH-59).
  # Attribution is by when a stamp drains the staging accumulator, and the
  # framework does not get control again until this phase returns -- so without
  # this line the very first sub-block below (waflib, which installs nothing at
  # all) would take every file lv2 just installed into .stamps/waflib-b600c92,
  # and lv2's own stamp would be written empty.
  mf_stage_claim

  _lv2_saved_dir=$(pwd)

  # waflib
  if stamp_check "waflib" "b600c92"; then
    fetch "https://gitlab.com/drobilla/autowaf/-/archive/b600c92/autowaf-b600c92.tar.gz" "autowaf.tar.gz"
    stamp_write "waflib" "b600c92"
  fi

  # serd
  if stamp_check "serd" "0.32.6"; then
    fetch "https://gitlab.com/drobilla/serd/-/archive/v0.32.6/serd-v0.32.6.tar.gz" "serd-v0.32.6.tar.gz"
    mf_meson build
    run ninja -C build
    run ninja -C build install
    stamp_write "serd" "0.32.6"
  fi

  # pcre
  if stamp_check "pcre" "8.45"; then
    fetch "https://sourceforge.net/projects/pcre/files/pcre/8.45/pcre-8.45.tar.gz/download" "pcre-8.45.tar.gz"
    run ./configure --prefix="$PREFIX" --disable-shared --enable-static
    run make -j "$MJOBS"
    run make install
    stamp_write "pcre" "8.45"
  fi

  # zix
  if stamp_check "zix" "0.8.0"; then
    fetch "https://gitlab.com/drobilla/zix/-/archive/v0.8.0/zix-v0.8.0.tar.gz" "zix-v0.8.0.tar.gz"
    # No `meson configure` step: -Dprefix and -Dlibdir are what mf_meson already
    # passes at setup, and -Dc_args REPLACES the value meson took from CFLAGS at
    # setup rather than adding to it (measured: c_args went from
    # [-fPIC, -I..., -fno-omit-frame-pointer] to [-march=native] alone). So the
    # line dropped mediaforge's composed flags from this one sub-build, and the
    # -march=native it added is a host-CPU-specific instruction set baked into a
    # shipped artifact -- the only such flag anywhere in the tree.
    mf_meson build
    cd build || die "Failed to cd to zix build"
    run meson compile
    run meson install
    stamp_write "zix" "0.8.0"
  fi

  # sord
  if stamp_check "sord" "0.16.20"; then
    fetch "https://gitlab.com/drobilla/sord/-/archive/v0.16.20/sord-v0.16.20.tar.gz" "sord-v0.16.20.tar.gz"
    mf_meson build
    run ninja -C build
    run ninja -C build install
    stamp_write "sord" "0.16.20"
  fi

  # sratom
  if stamp_check "sratom" "0.6.20"; then
    fetch "https://gitlab.com/lv2/sratom/-/archive/v0.6.20/sratom-v0.6.20.tar.gz" "sratom-v0.6.20.tar.gz"
    mf_meson build -Ddocs=disabled
    run ninja -C build
    run ninja -C build install
    stamp_write "sratom" "0.6.20"
  fi

  # lilv
  if stamp_check "lilv" "0.26.2"; then
    fetch "https://gitlab.com/lv2/lilv/-/archive/v0.26.2/lilv-v0.26.2.tar.gz" "lilv-v0.26.2.tar.gz"
    mf_meson build -Ddocs=disabled -Dcpp_std=c++11
    run ninja -C build
    run ninja -C build install
    stamp_write "lilv" "0.26.2"
  fi

  cd "$_lv2_saved_dir" || die "Failed to restore dir after lv2 sub-builds"
}

pkg_post_install() {
  printf '%s\n' "-I$PREFIX/include/lilv-0" >> "$PREFIX/.extra_cflags"
}
