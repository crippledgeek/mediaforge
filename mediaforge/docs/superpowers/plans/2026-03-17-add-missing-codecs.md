# Add Missing Codecs Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ~30 new library recipes to mediaforge for feature parity with media-autobuild_suite.

**Architecture:** Each library is a self-contained POSIX sh recipe file following existing framework conventions. Recipes set `PKG_*` variables, optionally override phase functions, and accumulate FFmpeg configure flags via `PKG_FFMPEG_OPT`. Build order in `_order.conf` encodes dependency chains. Version profiles pin all versions.

**Tech Stack:** POSIX sh, autoconf/cmake/meson build systems, pkg-config

**Spec:** `docs/superpowers/specs/2026-03-17-add-missing-codecs-design.md`

---

## Chunk 1: Subtitle/Text Rendering Stack (Tier A)

The most complex chunk due to the freetype2/harfbuzz circular dependency requiring a two-pass build.

### Task 1: Modify existing freetype2 recipe to explicitly disable harfbuzz

**Files:**
- Modify: `recipes/other/freetype2.sh`

- [ ] **Step 1: Add `--without-harfbuzz` to freetype2 configure**

```sh
PKG_NAME="FreeType2"
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfreetype"

# Explicitly disable harfbuzz in pass 1 — pass 2 (freetype2-harfbuzz.sh) rebuilds with it
PKG_CONFIGURE_FLAGS="--without-harfbuzz"
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/freetype2.sh`
Expected: no output (success)

- [ ] **Step 3: Commit**

```
git add recipes/other/freetype2.sh
git commit -m "feat(freetype2): explicitly disable harfbuzz for pass 1"
```

### Task 2: Create libxml2 recipe

**Files:**
- Create: `recipes/other/libxml2.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libxml2"
PKG_VERSION="${PKG_VERSION_LIBXML2:-2.13.6}"
PKG_GITHUB_REPO="GNOME/libxml2"
PKG_URL="https://github.com/GNOME/libxml2/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libxml2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxml2"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --without-python --without-readline --without-lzma \
    --without-debug --without-icu --with-zlib="$WORKSPACE"
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/libxml2.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/libxml2.sh
git commit -m "feat: add libxml2 recipe"
```

### Task 3: Create fribidi recipe

**Files:**
- Create: `recipes/other/fribidi.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="fribidi"
PKG_VERSION="${PKG_VERSION_FRIBIDI:-1.0.16}"
PKG_GITHUB_REPO="fribidi/fribidi"
PKG_URL="https://github.com/fribidi/fribidi/releases/download/v${PKG_VERSION}/fribidi-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfribidi"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Ddocs=false -Dtests=false
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/fribidi.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/fribidi.sh
git commit -m "feat: add fribidi recipe"
```

### Task 4: Create harfbuzz recipe

**Files:**
- Create: `recipes/other/harfbuzz.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="harfbuzz"
PKG_VERSION="${PKG_VERSION_HARFBUZZ:-10.4.0}"
PKG_GITHUB_REPO="harfbuzz/harfbuzz"
PKG_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${PKG_VERSION}/harfbuzz-${PKG_VERSION}.tar.xz"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/harfbuzz.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/harfbuzz.sh
git commit -m "feat: add harfbuzz recipe"
```

### Task 5: Create freetype2 pass 2 recipe (with harfbuzz)

**Files:**
- Create: `recipes/other/freetype2-harfbuzz.sh`

- [ ] **Step 1: Write recipe**

This recipe rebuilds freetype2 with harfbuzz support. It uses a different `PKG_NAME` (`FreeType2-hb`) so the done-file doesn't collide with the pass 1 build.

```sh
PKG_NAME="FreeType2-hb"
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"
# No PKG_FFMPEG_OPT — pass 1 already set --enable-libfreetype

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --with-harfbuzz=yes
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/freetype2-harfbuzz.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/freetype2-harfbuzz.sh
git commit -m "feat: add freetype2 pass 2 recipe (rebuild with harfbuzz)"
```

### Task 6: Create fontconfig recipe

**Files:**
- Create: `recipes/other/fontconfig.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="fontconfig"
PKG_VERSION="${PKG_VERSION_FONTCONFIG:-2.15.0}"
PKG_GITHUB_REPO="fontconfig/fontconfig"
PKG_URL="https://www.freedesktop.org/software/fontconfig/release/fontconfig-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfontconfig"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/fontconfig.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/fontconfig.sh
git commit -m "feat: add fontconfig recipe"
```

### Task 7: Create libass recipe

**Files:**
- Create: `recipes/other/libass.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libass"
PKG_VERSION="${PKG_VERSION_LIBASS:-0.17.3}"
PKG_GITHUB_REPO="libass/libass"
PKG_URL="https://github.com/libass/libass/releases/download/${PKG_VERSION}/libass-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libass"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-require-system-font-provider
}
```

- [ ] **Step 2: Syntax check**

Run: `sh -n recipes/other/libass.sh`

- [ ] **Step 3: Commit**

```
git add recipes/other/libass.sh
git commit -m "feat: add libass recipe"
```

### Task 8: Update build order for Tier A

**Files:**
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Insert subtitle/text stack after freetype2**

Add these lines after `recipes/other/freetype2.sh` and before `recipes/other/vapoursynth.sh`:

```
# Subtitle/text rendering (two-pass freetype2/harfbuzz)
recipes/other/libxml2.sh
recipes/other/fribidi.sh
recipes/other/harfbuzz.sh
recipes/other/freetype2-harfbuzz.sh
recipes/other/fontconfig.sh
recipes/other/libass.sh
```

- [ ] **Step 2: Syntax check all new recipes**

Run: `for f in recipes/other/libxml2.sh recipes/other/fribidi.sh recipes/other/harfbuzz.sh recipes/other/freetype2-harfbuzz.sh recipes/other/fontconfig.sh recipes/other/libass.sh; do sh -n "$f" && echo "OK: $f"; done`

- [ ] **Step 3: Commit**

```
git add recipes/_order.conf
git commit -m "feat: add subtitle/text rendering stack to build order"
```

---

## Chunk 2: Additional Audio Codecs (Tier B)

### Task 9: Create speex recipe

**Files:**
- Create: `recipes/audio/speex.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="speex"
PKG_VERSION="${PKG_VERSION_SPEEX:-1.2.1}"
PKG_GITHUB_REPO="xiph/speex"
PKG_URL="https://downloads.xiph.org/releases/speex/speex-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libspeex"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/audio/speex.sh
git add recipes/audio/speex.sh
git commit -m "feat: add speex recipe"
```

### Task 10: Create twolame recipe

**Files:**
- Create: `recipes/audio/twolame.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="twolame"
PKG_VERSION="${PKG_VERSION_TWOLAME:-0.4.0}"
PKG_URL="https://sourceforge.net/projects/twolame/files/twolame/${PKG_VERSION}/twolame-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="twolame-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtwolame"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/audio/twolame.sh
git add recipes/audio/twolame.sh
git commit -m "feat: add twolame recipe"
```

### Task 11: Create gsm recipe

**Files:**
- Create: `recipes/audio/gsm.sh`

- [ ] **Step 1: Write recipe**

gsm uses a plain Makefile with no configure script. Needs `-std=gnu11` for GCC 15 C23 compat.

```sh
PKG_NAME="gsm"
PKG_VERSION="${PKG_VERSION_GSM:-1.0.22}"
PKG_URL="https://www.quut.com/gsm/gsm-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libgsm"

# gsm has old C code incompatible with C23 (GCC 15+ defaults to -std=gnu23)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  :
}

pkg_build() {
  execute make -j "$MJOBS" INSTALL_ROOT="$WORKSPACE" \
    CC="gcc" CCFLAGS="$CFLAGS -c -DNeedFunctionPrototypes=1 -Wall -fPIC"
}

pkg_install() {
  mkdir -p "$WORKSPACE/include/gsm" "$WORKSPACE/lib"
  cp inc/gsm.h "$WORKSPACE/include/gsm/"
  cp lib/libgsm.a "$WORKSPACE/lib/"
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/audio/gsm.sh
git add recipes/audio/gsm.sh
git commit -m "feat: add gsm recipe"
```

### Task 12: Create libilbc recipe

**Files:**
- Create: `recipes/audio/libilbc.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libilbc"
PKG_VERSION="${PKG_VERSION_LIBILBC:-3.0.4}"
PKG_GITHUB_REPO="nicoboss/libilbc"
PKG_URL="https://github.com/nicoboss/libilbc/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libilbc-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libilbc"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/audio/libilbc.sh
git add recipes/audio/libilbc.sh
git commit -m "feat: add libilbc recipe"
```

### Task 13: Create vo-amrwbenc recipe

**Files:**
- Create: `recipes/audio/vo_amrwbenc.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="vo_amrwbenc"
PKG_VERSION="${PKG_VERSION_VO_AMRWBENC:-0.1.3}"
PKG_URL="https://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/vo-amrwbenc-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="vo-amrwbenc-${PKG_VERSION}.tar.gz"
PKG_DIRNAME="vo-amrwbenc-${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-libvo-amrwbenc"
PKG_NONFREE=true
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/audio/vo_amrwbenc.sh
git add recipes/audio/vo_amrwbenc.sh
git commit -m "feat: add vo-amrwbenc recipe (nonfree)"
```

### Task 14: Update build order for Tier B

**Files:**
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Insert after existing audio block (after `recipes/audio/soxr.sh`)**

```
# Additional audio codecs
recipes/audio/speex.sh
recipes/audio/twolame.sh
recipes/audio/gsm.sh
recipes/audio/libilbc.sh
recipes/audio/vo_amrwbenc.sh
```

- [ ] **Step 2: Commit**

```
git add recipes/_order.conf
git commit -m "feat: add audio codec recipes to build order"
```

---

## Chunk 3: Video Codecs, Image, Media Formats (Tiers C + D)

### Task 15: Create kvazaar recipe

**Files:**
- Create: `recipes/video/kvazaar.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="kvazaar"
PKG_VERSION="${PKG_VERSION_KVAZAAR:-2.3.1}"
PKG_GITHUB_REPO="ultravideo/kvazaar"
PKG_URL="https://github.com/ultravideo/kvazaar/releases/download/v${PKG_VERSION}/kvazaar-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libkvazaar"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/video/kvazaar.sh
git add recipes/video/kvazaar.sh
git commit -m "feat: add kvazaar recipe"
```

### Task 16: Create openh264 recipe

**Files:**
- Create: `recipes/video/openh264.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="openh264"
PKG_VERSION="${PKG_VERSION_OPENH264:-2.6.0}"
PKG_GITHUB_REPO="cisco/openh264"
PKG_URL="https://github.com/cisco/openh264/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openh264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenh264"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib"
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/video/openh264.sh
git add recipes/video/openh264.sh
git commit -m "feat: add openh264 recipe"
```

### Task 17: Create openjpeg recipe

**Files:**
- Create: `recipes/image/openjpeg.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="openjpeg"
PKG_VERSION="${PKG_VERSION_OPENJPEG:-2.5.3}"
PKG_GITHUB_REPO="uclouvain/openjpeg"
PKG_URL="https://github.com/uclouvain/openjpeg/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openjpeg-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenjpeg"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_CODEC=OFF"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/image/openjpeg.sh
git add recipes/image/openjpeg.sh
git commit -m "feat: add openjpeg recipe"
```

### Task 18: Create libbluray recipe

**Files:**
- Create: `recipes/other/libbluray.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libbluray"
PKG_VERSION="${PKG_VERSION_LIBBLURAY:-1.3.4}"
PKG_GITHUB_REPO="videolan/libbluray"
PKG_URL="https://download.videolan.org/pub/videolan/libbluray/${PKG_VERSION}/libbluray-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-libbluray"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-bdjava-jar --disable-doxygen-doc --disable-examples
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libbluray.sh
git add recipes/other/libbluray.sh
git commit -m "feat: add libbluray recipe"
```

### Task 19: Create librtmp recipe

**Files:**
- Create: `recipes/other/librtmp.sh`

- [ ] **Step 1: Write recipe**

librtmp has no configure script, just a Makefile. Needs `-std=gnu11` for GCC 15.

```sh
PKG_NAME="librtmp"
PKG_VERSION="${PKG_VERSION_LIBRTMP:-fa8646d}"
PKG_URL="https://git.ffmpeg.org/gitweb/rtmpdump.git/snapshot/${PKG_VERSION}.tar.gz"
PKG_FILENAME="rtmpdump-${PKG_VERSION}.tar.gz"

# librtmp has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  :
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  execute make SYS=posix prefix="$WORKSPACE" \
    SHARED= CRYPTO=OPENSSL \
    XCFLAGS="$CFLAGS -I$WORKSPACE/include" \
    XLDFLAGS="-L$WORKSPACE/lib" \
    LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
}

pkg_install() {
  execute make SYS=posix prefix="$WORKSPACE" SHARED= install
}

pkg_post_install() {
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-librtmp"
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/librtmp.sh
git add recipes/other/librtmp.sh
git commit -m "feat: add librtmp recipe"
```

### Task 20: Update build order for Tiers C + D

**Files:**
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Insert video codecs after existing video block, image after image block, libbluray/librtmp after libass**

Video (after `recipes/video/zimg.sh`):
```
recipes/video/kvazaar.sh
recipes/video/openh264.sh
```

Image (after `recipes/image/libwebp.sh`):
```
recipes/image/openjpeg.sh
```

Other (after `recipes/other/libass.sh`):
```
recipes/other/libbluray.sh
recipes/other/librtmp.sh
```

- [ ] **Step 2: Commit**

```
git add recipes/_order.conf
git commit -m "feat: add video/image/media format recipes to build order"
```

---

## Chunk 4: Audio Processing + Filter Plugins (Tiers E + F)

### Task 21: Create rubberband recipe

**Files:**
- Create: `recipes/other/rubberband.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="rubberband"
PKG_VERSION="${PKG_VERSION_RUBBERBAND:-4.0.0}"
PKG_GITHUB_REPO="breakfastquay/rubberband"
PKG_URL="https://breakfastquay.com/files/releases/rubberband-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-librubberband"
PKG_GPL=true
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dfft=builtin -Dresampler=builtin -Dtests=disabled
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/rubberband.sh
git add recipes/other/rubberband.sh
git commit -m "feat: add rubberband recipe (GPL)"
```

### Task 22: Create libmysofa recipe

**Files:**
- Create: `recipes/other/libmysofa.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libmysofa"
PKG_VERSION="${PKG_VERSION_LIBMYSOFA:-1.3.3}"
PKG_GITHUB_REPO="hoene/libmysofa"
PKG_URL="https://github.com/hoene/libmysofa/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libmysofa-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libmysofa"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libmysofa.sh
git add recipes/other/libmysofa.sh
git commit -m "feat: add libmysofa recipe"
```

### Task 23: Create bs2b recipe

**Files:**
- Create: `recipes/other/bs2b.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="bs2b"
PKG_VERSION="${PKG_VERSION_BS2B:-3.1.0}"
PKG_URL="https://downloads.sourceforge.net/bs2b/libbs2b-${PKG_VERSION}.tar.lzma"
PKG_FILENAME="libbs2b-${PKG_VERSION}.tar.lzma"
PKG_DIRNAME="libbs2b-${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-libbs2b"

# bs2b has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/bs2b.sh
git add recipes/other/bs2b.sh
git commit -m "feat: add bs2b recipe"
```

### Task 24: Create chromaprint recipe

**Files:**
- Create: `recipes/other/chromaprint.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="chromaprint"
PKG_VERSION="${PKG_VERSION_CHROMAPRINT:-1.5.1}"
PKG_GITHUB_REPO="acoustid/chromaprint"
PKG_URL="https://github.com/acoustid/chromaprint/releases/download/v${PKG_VERSION}/chromaprint-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-chromaprint"
PKG_CMAKE=true
# Disable tools to avoid circular FFmpeg dependency
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/chromaprint.sh
git add recipes/other/chromaprint.sh
git commit -m "feat: add chromaprint recipe"
```

### Task 25: Create frei0r recipe

**Files:**
- Create: `recipes/other/frei0r.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="frei0r"
PKG_VERSION="${PKG_VERSION_FREI0R:-2.3.3}"
PKG_GITHUB_REPO="dyne/frei0r"
PKG_URL="https://github.com/dyne/frei0r/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="frei0r-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-frei0r"
PKG_GPL=true
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DWITHOUT_OPENCV=ON"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/frei0r.sh
git add recipes/other/frei0r.sh
git commit -m "feat: add frei0r recipe (GPL)"
```

### Task 26: Create ladspa recipe

**Files:**
- Create: `recipes/other/ladspa.sh`

- [ ] **Step 1: Write recipe**

ladspa is headers-only — just installs `ladspa.h`.

```sh
PKG_NAME="ladspa"
PKG_VERSION="${PKG_VERSION_LADSPA:-1.17}"
PKG_URL="https://www.ladspa.org/download/ladspa_sdk_${PKG_VERSION}.tgz"
PKG_FILENAME="ladspa_sdk_${PKG_VERSION}.tgz"
PKG_DIRNAME="ladspa_sdk_${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-ladspa"

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  execute cp src/ladspa.h "$WORKSPACE/include/"
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/ladspa.sh
git add recipes/other/ladspa.sh
git commit -m "feat: add ladspa recipe (headers-only)"
```

### Task 27: Update build order for Tiers E + F

**Files:**
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Insert after existing other block (after `recipes/other/libzmq.sh`)**

```
# Audio processing
recipes/other/rubberband.sh
recipes/other/libmysofa.sh
recipes/other/bs2b.sh
recipes/other/chromaprint.sh

# Filter plugins
recipes/other/frei0r.sh
recipes/other/ladspa.sh
```

- [ ] **Step 2: Commit**

```
git add recipes/_order.conf
git commit -m "feat: add audio processing and filter plugin recipes to build order"
```

---

## Chunk 5: Miscellaneous Libraries (Tier G)

### Task 28: Create librist recipe

**Files:**
- Create: `recipes/other/librist.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="librist"
PKG_VERSION="${PKG_VERSION_LIBRIST:-0.2.12}"
PKG_GITHUB_REPO="xiph/librist"
PKG_URL="https://code.videolan.org/rist/librist/-/archive/v${PKG_VERSION}/librist-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="librist-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librist"
PKG_REQUIRES_MESON=true

pkg_configure() {
  make_dir build
  execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib" \
    -Dbuilt_tools=false -Dtest=false
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/librist.sh
git add recipes/other/librist.sh
git commit -m "feat: add librist recipe"
```

### Task 29: Create libcaca recipe

**Files:**
- Create: `recipes/other/libcaca.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libcaca"
PKG_VERSION="${PKG_VERSION_LIBCACA:-0.99.beta20}"
PKG_URL="https://github.com/cacalabs/libcaca/releases/download/v${PKG_VERSION}/libcaca-${PKG_VERSION}.tar.bz2"
PKG_GITHUB_REPO="cacalabs/libcaca"
PKG_FFMPEG_OPT="--enable-libcaca"

# libcaca has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-doc --disable-java --disable-csharp --disable-ruby \
    --disable-python --disable-x11 --disable-gl --disable-cocoa \
    --disable-ncurses --disable-slang
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libcaca.sh
git add recipes/other/libcaca.sh
git commit -m "feat: add libcaca recipe"
```

### Task 30: Create codec2 recipe

**Files:**
- Create: `recipes/other/codec2.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="codec2"
PKG_VERSION="${PKG_VERSION_CODEC2:-1.2.0}"
PKG_GITHUB_REPO="drowe67/codec2"
PKG_URL="https://github.com/drowe67/codec2/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="codec2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libcodec2"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DUNITTEST=OFF"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/codec2.sh
git add recipes/other/codec2.sh
git commit -m "feat: add codec2 recipe"
```

### Task 31: Create flite recipe

**Files:**
- Create: `recipes/other/flite.sh`

- [ ] **Step 1: Write recipe**

flite uses a custom configure/make (not autoconf). Needs `-std=gnu11` for GCC 15.

```sh
PKG_NAME="flite"
PKG_VERSION="${PKG_VERSION_FLITE:-2.2}"
PKG_URL="https://github.com/festvox/flite/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="flite-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="festvox/flite"
PKG_FFMPEG_OPT="--enable-libflite"

# flite has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --with-pic
}

pkg_install() {
  execute make install
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/flite.sh
git add recipes/other/flite.sh
git commit -m "feat: add flite recipe"
```

### Task 32: Create libgme recipe

**Files:**
- Create: `recipes/other/libgme.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libgme"
PKG_VERSION="${PKG_VERSION_LIBGME:-0.6.3}"
PKG_GITHUB_REPO="libgme/game-music-emu"
PKG_URL="https://github.com/libgme/game-music-emu/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="game-music-emu-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libgme"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DENABLE_UBSAN=OFF"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libgme.sh
git add recipes/other/libgme.sh
git commit -m "feat: add libgme recipe"
```

### Task 33: Create libopenmpt recipe

**Files:**
- Create: `recipes/other/libopenmpt.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libopenmpt"
PKG_VERSION="${PKG_VERSION_LIBOPENMPT:-0.7.14}"
PKG_URL="https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${PKG_VERSION}+release.autotools.tar.gz"
PKG_FILENAME="libopenmpt-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenmpt"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-examples --disable-tests --disable-openmpt123 \
    --without-mpg123 --without-portaudio --without-portaudiocpp
}
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libopenmpt.sh
git add recipes/other/libopenmpt.sh
git commit -m "feat: add libopenmpt recipe"
```

### Task 34: Create libshine recipe

**Files:**
- Create: `recipes/other/libshine.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libshine"
PKG_VERSION="${PKG_VERSION_LIBSHINE:-3.1.1}"
PKG_URL="https://github.com/toots/shine/releases/download/${PKG_VERSION}/shine-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="toots/shine"
PKG_FFMPEG_OPT="--enable-libshine"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libshine.sh
git add recipes/other/libshine.sh
git commit -m "feat: add libshine recipe"
```

### Task 35: Create libsnappy recipe

**Files:**
- Create: `recipes/other/libsnappy.sh`

- [ ] **Step 1: Write recipe**

```sh
PKG_NAME="libsnappy"
PKG_VERSION="${PKG_VERSION_LIBSNAPPY:-1.2.1}"
PKG_GITHUB_REPO="google/snappy"
PKG_URL="https://github.com/google/snappy/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="snappy-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsnappy"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF"
```

- [ ] **Step 2: Syntax check and commit**

```
sh -n recipes/other/libsnappy.sh
git add recipes/other/libsnappy.sh
git commit -m "feat: add libsnappy recipe"
```

### Task 36: Update build order for Tier G

**Files:**
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Insert before HW acceleration block**

```
# Miscellaneous
recipes/other/librist.sh
recipes/other/libcaca.sh
recipes/other/codec2.sh
recipes/other/flite.sh
recipes/other/libgme.sh
recipes/other/libopenmpt.sh
recipes/other/libshine.sh
recipes/other/libsnappy.sh
```

- [ ] **Step 2: Commit**

```
git add recipes/_order.conf
git commit -m "feat: add miscellaneous recipes to build order"
```

---

## Chunk 6: Version Profiles + Final Integration

### Task 37: Update ffmpeg-8.0.1 profile with new library versions

**Files:**
- Modify: `profiles/ffmpeg-8.0.1.conf`

- [ ] **Step 1: Add version pins for all 30+ new libraries**

Append to the profile (organized by category):

```sh
# ── Subtitle/Text ──
PKG_VERSION_LIBXML2="2.13.6"
PKG_VERSION_FRIBIDI="1.0.16"
PKG_VERSION_HARFBUZZ="10.4.0"
PKG_VERSION_FONTCONFIG="2.15.0"
PKG_VERSION_LIBASS="0.17.3"

# ── Additional Audio ──
PKG_VERSION_SPEEX="1.2.1"
PKG_VERSION_TWOLAME="0.4.0"
PKG_VERSION_GSM="1.0.22"
PKG_VERSION_LIBILBC="3.0.4"
PKG_VERSION_VO_AMRWBENC="0.1.3"

# ── Additional Video ──
PKG_VERSION_KVAZAAR="2.3.1"
PKG_VERSION_OPENH264="2.6.0"

# ── Image ──
PKG_VERSION_OPENJPEG="2.5.3"

# ── Media Format ──
PKG_VERSION_LIBBLURAY="1.3.4"
PKG_VERSION_LIBRTMP="fa8646d"

# ── Audio Processing ──
PKG_VERSION_RUBBERBAND="4.0.0"
PKG_VERSION_LIBMYSOFA="1.3.3"
PKG_VERSION_BS2B="3.1.0"
PKG_VERSION_CHROMAPRINT="1.5.1"

# ── Filter Plugins ──
PKG_VERSION_FREI0R="2.3.3"
PKG_VERSION_LADSPA="1.17"

# ── Miscellaneous ──
PKG_VERSION_LIBRIST="0.2.12"
PKG_VERSION_LIBCACA="0.99.beta20"
PKG_VERSION_CODEC2="1.2.0"
PKG_VERSION_FLITE="2.2"
PKG_VERSION_LIBGME="0.6.3"
PKG_VERSION_LIBOPENMPT="0.7.14"
PKG_VERSION_LIBSHINE="3.1.1"
PKG_VERSION_LIBSNAPPY="1.2.1"
```

- [ ] **Step 2: Commit**

```
git add profiles/ffmpeg-8.0.1.conf
git commit -m "feat: add new library version pins to 8.0.1 profile"
```

### Task 38: Update remaining profiles (7.1, 7.0, 6.1)

**Files:**
- Modify: `profiles/ffmpeg-7.1.conf`
- Modify: `profiles/ffmpeg-7.0.conf`
- Modify: `profiles/ffmpeg-6.1.conf`

- [ ] **Step 1: Add same version pins to all three profiles**

Use the same versions as 8.0.1 — all FFmpeg flags used here have been available since FFmpeg 4.x+.

- [ ] **Step 2: Commit**

```
git add profiles/ffmpeg-7.1.conf profiles/ffmpeg-7.0.conf profiles/ffmpeg-6.1.conf
git commit -m "feat: add new library version pins to all profiles"
```

### Task 39: Update CLAUDE.md architecture section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the recipe count and add new categories to the architecture description**

Change "~50 modular dependency recipes" to "~80 modular dependency recipes" where referenced.

- [ ] **Step 2: Commit**

```
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for new recipe count"
```

### Task 40: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update feature descriptions to mention new capabilities**

Add subtitle rendering (libass), additional codecs, and filter plugins to the feature list.

- [ ] **Step 2: Commit**

```
git add README.md
git commit -m "docs: update README with new library additions"
```

### Task 41: Full syntax check of all new recipes

- [ ] **Step 1: Run syntax check**

Run: `for f in recipes/other/libxml2.sh recipes/other/fribidi.sh recipes/other/harfbuzz.sh recipes/other/freetype2-harfbuzz.sh recipes/other/fontconfig.sh recipes/other/libass.sh recipes/audio/speex.sh recipes/audio/twolame.sh recipes/audio/gsm.sh recipes/audio/libilbc.sh recipes/audio/vo_amrwbenc.sh recipes/video/kvazaar.sh recipes/video/openh264.sh recipes/image/openjpeg.sh recipes/other/libbluray.sh recipes/other/librtmp.sh recipes/other/rubberband.sh recipes/other/libmysofa.sh recipes/other/bs2b.sh recipes/other/chromaprint.sh recipes/other/frei0r.sh recipes/other/ladspa.sh recipes/other/librist.sh recipes/other/libcaca.sh recipes/other/codec2.sh recipes/other/flite.sh recipes/other/libgme.sh recipes/other/libopenmpt.sh recipes/other/libshine.sh recipes/other/libsnappy.sh; do sh -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done`

Expected: All OK

### Task 42: Test build (smoke test)

- [ ] **Step 1: Clean all done files and run a full build**

Run: `./mediaforge.sh -c && ./mediaforge.sh -b --nonfree`

Expected: All recipes build successfully, FFmpeg configure picks up all new `--enable-*` flags.
