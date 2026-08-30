# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="x265"
PKG_VERSION="${PKG_VERSION_X265:-4.1}"
PKG_URL="https://download.videolan.org/pub/videolan/x265/x265_${PKG_VERSION}.tar.gz"
PKG_FILENAME="x265-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx265"
PKG_GPL=true
PKG_MUTEX_GROUP="h265"

# x265 4.1 bundles json11.cpp which uses uint8_t without #include <cstdint>
# (GCC 15 no longer transitively includes it)
pkg_prepare() {
  _json11="source/dynamicHDR10/json11/json11.cpp"
  if ! grep -q '<cstdint>' "$_json11"; then
    sed '/#include <limits>/a #include <cstdint>' "$_json11" > "$_json11.tmp" \
      && mv "$_json11.tmp" "$_json11"
  fi

  # x265 4.1's source/CMakeLists.txt sets CMP0025/CMP0054 to OLD and declares
  # cmake_minimum_required 2.8.8 — both rejected by the bundled cmake 4.x. The
  # CMAKE_POLICY_VERSION_MINIMUM floor can't override an explicit SET ... OLD.
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/x265-cmake4-policy.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/x265-cmake4-policy.patch" >/dev/null 2>&1 \
      || die "x265-cmake4-policy.patch failed to apply"
  fi
}

pkg_configure() {
  :
}

pkg_build() {
  cd build/linux || die "Failed to cd to build/linux"
  rm -rf 8bit 10bit 12bit 2>/dev/null
  mkdir -p 8bit 10bit 12bit

  # NUMA support requires libnuma.a, which Arch doesn't ship. Disable for
  # static builds so x265.pc's Libs.private doesn't reference -lnuma.
  _x265_numa=""
  [ -n "$LDEXEFLAGS" ] && _x265_numa="-DENABLE_LIBNUMA=OFF"

  cd 12bit || die "Failed to cd to 12bit"
  mf_cmake ../../../source \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF $_x265_numa -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF -DMAIN12=ON
  run make -j "$MJOBS"

  cd ../10bit || die "Failed to cd to 10bit"
  mf_cmake ../../../source \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF $_x265_numa -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
  run make -j "$MJOBS"

  cd ../8bit || die "Failed to cd to 8bit"
  ln -sf ../10bit/libx265.a libx265_main10.a
  ln -sf ../12bit/libx265.a libx265_main12.a
  mf_cmake ../../../source \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF $_x265_numa \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a;-ldl" \
    -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  run make -j "$MJOBS"

  mv libx265.a libx265_main.a

  if [ "$OS_MACOS" = true ]; then
    run "$GNU_LIBTOOL" -static -o libx265.a \
      libx265_main.a libx265_main10.a libx265_main12.a 2>/dev/null
  else
    run_stdin ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
  fi
}

pkg_install() {
  run make install
}

pkg_post_install() {
  mf_pc_static_libgcc x265
}
