PKG_NAME="x265"
PKG_VERSION="${PKG_VERSION_X265:-4.1}"
PKG_URL="https://bitbucket.org/multicoreware/x265_git/downloads/x265_${PKG_VERSION}.tar.gz"
PKG_FILENAME="x265-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx265"
PKG_GPL=true

# x265 4.1 bundles json11.cpp which uses uint8_t without #include <cstdint>
# (GCC 15 no longer transitively includes it)
pkg_prepare() {
  _json11="source/dynamicHDR10/json11/json11.cpp"
  if ! grep -q '<cstdint>' "$_json11"; then
    sed '/#include <limits>/a #include <cstdint>' "$_json11" > "$_json11.tmp" \
      && mv "$_json11.tmp" "$_json11"
  fi
}

pkg_configure() {
  :
}

pkg_build() {
  cd build/linux || die "Failed to cd to build/linux"
  rm -rf 8bit 10bit 12bit 2>/dev/null
  mkdir -p 8bit 10bit 12bit

  cd 12bit || die "Failed to cd to 12bit"
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF -DMAIN12=ON
  execute make -j "$MJOBS"

  cd ../10bit || die "Failed to cd to 10bit"
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
  execute make -j "$MJOBS"

  cd ../8bit || die "Failed to cd to 8bit"
  ln -sf ../10bit/libx265.a libx265_main10.a
  ln -sf ../12bit/libx265.a libx265_main12.a
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a;-ldl" \
    -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  execute make -j "$MJOBS"

  mv libx265.a libx265_main.a

  if [ "$OS_MACOS" = true ]; then
    execute "$GNU_LIBTOOL" -static -o libx265.a \
      libx265_main.a libx265_main10.a libx265_main12.a 2>/dev/null
  else
    execute_stdin ar -M <<EOF
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
  execute make install
}

pkg_post_install() {
  if [ -n "$LDEXEFLAGS" ]; then
    sed 's/-lgcc_s/-lgcc_eh/g' "$PREFIX/lib/pkgconfig/x265.pc" \
      > "$PREFIX/lib/pkgconfig/x265.pc.tmp" \
      && mv "$PREFIX/lib/pkgconfig/x265.pc.tmp" "$PREFIX/lib/pkgconfig/x265.pc"
  fi
}
