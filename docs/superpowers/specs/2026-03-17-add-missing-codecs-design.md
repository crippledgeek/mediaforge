# Add Missing Codecs and Libraries

**Date:** 2026-03-17
**Status:** Approved

## Summary

Add ~30 libraries to mediaforge to reach feature parity with media-autobuild_suite. All libraries follow existing recipe conventions (POSIX sh, version-pinned, license-gated).

## New Recipes

### Tier A — Subtitle/Text Rendering

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| libxml2 | 2.13.6 | `--enable-libxml2` | autoconf | zlib | MIT |
| fribidi | 1.0.16 | `--enable-libfribidi` | meson | none | LGPL |
| harfbuzz | 10.4.0 | (via freetype/libass) | meson | freetype2 | MIT |
| fontconfig | 2.15.0 | `--enable-libfontconfig` | meson | freetype2, libxml2 | MIT |
| libass | 0.17.3 | `--enable-libass` | autoconf | freetype2, fribidi, harfbuzz, fontconfig | ISC |

**Dependency chain:** freetype2 → harfbuzz → fontconfig → libass (with fribidi as independent dep of libass). libxml2 is needed by fontconfig and libbluray.

**Harfbuzz/FreeType circular dependency resolution:** FreeType can optionally use harfbuzz for auto-hinting, and harfbuzz requires freetype2. We use the two-pass rebuild approach (Linux From Scratch / Gentoo standard):

1. **freetype2 (pass 1)** — builds without harfbuzz (`--without-harfbuzz`). Already exists in `_order.conf` at its current position.
2. **harfbuzz** — builds with freetype2 support (finds the pass-1 freetype2).
3. **freetype2 (pass 2)** — rebuilds WITH harfbuzz support. Uses a new recipe entry `recipes/other/freetype2-harfbuzz.sh` that forces a rebuild by using a different done-file name (e.g., `FreeType2-hb.done`). The existing freetype2 recipe is modified to explicitly pass `--without-harfbuzz` to prevent accidental harfbuzz detection.
4. **fontconfig** — builds with the harfbuzz-enabled freetype2.
5. **libass** — builds with all four deps.

This gives full harfbuzz integration in freetype2, matching what distributions like Arch and Gentoo ship. The second pass overwrites the same `$WORKSPACE` files (headers + `libfreetype.a`), so downstream consumers automatically get the harfbuzz-enabled build.

### Tier B — Additional Audio Codecs

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| speex | 1.2.1 | `--enable-libspeex` | autoconf | libogg | BSD |
| twolame | 0.4.0 | `--enable-libtwolame` | autoconf | none | LGPL |
| gsm | 1.0.22 | `--enable-libgsm` | make (no configure) | none | ISC |
| libilbc | 3.0.4 | `--enable-libilbc` | cmake | none | BSD |
| vo-amrwbenc | 0.1.3 | `--enable-libvo-amrwbenc` | autoconf | none | Apache (nonfree per FFmpeg) |

### Tier C — Additional Video Codecs

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| kvazaar | 2.3.1 | `--enable-libkvazaar` | autoconf | none | LGPL |
| openh264 | 2.6.0 | `--enable-libopenh264` | meson | none | BSD |

### Tier D — Media Format Support

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| openjpeg | 2.5.3 | `--enable-libopenjpeg` | cmake | none | BSD |
| libbluray | 1.3.4 | `--enable-libbluray` | autoconf | fontconfig, libxml2, freetype2 | LGPL |
| librtmp | fa8646d (2021-02-10 snapshot) | `--enable-librtmp` | make | openssl or gnutls, zlib | LGPL |

### Tier E — Audio Processing

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| rubberband | 4.0.0 | `--enable-librubberband` | meson | none (bundles resampler + FFT in static builds) | GPL |
| libmysofa | 1.3.3 | `--enable-libmysofa` | cmake | zlib | BSD |
| bs2b | 3.1.0 | `--enable-libbs2b` | autoconf | none | MIT |
| chromaprint | 1.5.1 | `--enable-chromaprint` | cmake | none (built with `-DBUILD_TOOLS=OFF` to avoid circular FFmpeg dep) | LGPL |

### Tier F — Filter Plugins

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| frei0r | 2.3.3 | `--enable-frei0r` | cmake | none | GPL |
| ladspa | 1.17 | `--enable-ladspa` | headers-only (`PKG_SKIP_EXTRACT=false`, downloads SDK, installs `ladspa.h` only) | none | LGPL |

### Tier G — Miscellaneous

| Library | Version | FFmpeg Flag | Build System | Dependencies | License |
|---------|---------|-------------|--------------|--------------|---------|
| librist | 0.2.12 | `--enable-librist` | meson | none | BSD |
| libcaca | 0.99.beta20 | `--enable-libcaca` | autoconf | none | WTFPL |
| codec2 | 1.2.0 | `--enable-libcodec2` | cmake | none | LGPL |
| flite | 2.2 | `--enable-libflite` | make (custom) | none | BSD |
| libgme | 0.6.3 | `--enable-libgme` | cmake | none | LGPL |
| libopenmpt | 0.7.14 | `--enable-libopenmpt` | autoconf | zlib, libogg, libvorbis (already built) | BSD |
| libshine | 3.1.1 | `--enable-libshine` | autoconf | none | LGPL |
| libsnappy | 1.2.1 | `--enable-libsnappy` | cmake | none | BSD |

## License Gating

| Guard | Libraries | Reason |
|-------|-----------|--------|
| `PKG_GPL=true` | rubberband, frei0r | GPL-licensed |
| `PKG_NONFREE=true` | vo-amrwbenc | Treated as nonfree by FFmpeg |
| `PKG_REQUIRES_MESON=true` | fribidi, harfbuzz, fontconfig, openh264, rubberband, librist | Meson build system |

All other libraries are free and build unconditionally.

## Build Order

New entries in `_order.conf`, inserted to respect dependency chains:

```
# ── Existing: tools, crypto, cmake ──

# ── Existing: video codecs ──
# NEW video codecs (after existing video block)
recipes/video/kvazaar.sh
recipes/video/openh264.sh

# ── Existing: audio codecs ──
# NEW audio codecs (after existing audio block)
recipes/audio/speex.sh
recipes/audio/twolame.sh
recipes/audio/gsm.sh
recipes/audio/libilbc.sh
recipes/audio/vo_amrwbenc.sh

# ── Existing: image libraries ──
# NEW image
recipes/image/openjpeg.sh

# ── Existing: other libraries (libsdl, freetype2, ...) ──
# NEW subtitle/text stack (after freetype2, order matters)
recipes/other/libxml2.sh
recipes/other/fribidi.sh
recipes/other/harfbuzz.sh
recipes/other/freetype2-harfbuzz.sh   # freetype2 pass 2 (rebuilt with harfbuzz)
recipes/other/fontconfig.sh
recipes/other/libass.sh

# NEW media format support (after subtitle stack)
recipes/other/libbluray.sh
recipes/other/librtmp.sh

# ── Existing: vapoursynth, srt, zvbi, libzmq ──

# NEW audio processing
recipes/other/rubberband.sh
recipes/other/libmysofa.sh
recipes/other/bs2b.sh
recipes/other/chromaprint.sh

# NEW filter plugins
recipes/other/frei0r.sh
recipes/other/ladspa.sh

# NEW miscellaneous
recipes/other/librist.sh
recipes/other/libcaca.sh
recipes/other/codec2.sh
recipes/other/flite.sh
recipes/other/libgme.sh
recipes/other/libopenmpt.sh
recipes/other/libshine.sh
recipes/other/libsnappy.sh

# ── Existing: HW acceleration ──
```

### Critical ordering constraints

1. **libxml2** before fontconfig and libbluray (compile-time dependency)
2. **fribidi** before libass (compile-time dependency)
3. **harfbuzz** after freetype2 pass 1, before freetype2 pass 2
4. **freetype2-harfbuzz** (pass 2) after harfbuzz — rebuilds freetype2 with harfbuzz support
5. **fontconfig** after freetype2 pass 2 and libxml2, before libass
6. **libass** after all four deps (freetype2, fribidi, harfbuzz, fontconfig)
6. **libbluray** after fontconfig, libxml2, freetype2
7. **librtmp** after openssl or gnutls (crypto must be built first — already guaranteed by order)
8. **speex** after libogg (already built in audio block)

## Profile Updates

All 4 profiles get `PKG_VERSION_*` pins for each new library. Versions listed above are for the 8.0.1 profile. Older profiles use the same versions unless FFmpeg configure support was added later, in which case the recipe is omitted from that profile.

## Recipe Conventions

All new recipes follow existing patterns:
- POSIX sh only (no bashisms)
- `PKG_VERSION="${PKG_VERSION_NAME:-default}"` for profile pinning
- `PKG_GITHUB_REPO` set where applicable (for `--check-updates`)
- GCC 15 C23 workaround (`CFLAGS="$CFLAGS -std=gnu11"; export CFLAGS`) added to: gsm, flite, librtmp, libcaca, bs2b (old C codebases)
- Minimal phase overrides (use defaults where autoconf/cmake works out of the box)
- `PKG_GITHUB_REPO` set for: harfbuzz (harfbuzz/harfbuzz), fontconfig (fontconfig/fontconfig), libass (libass/libass), fribidi (fribidi/fribidi), kvazaar (ultravideo/kvazaar), openh264 (cisco/openh264), openjpeg (uclouvain/openjpeg), libbluray (videolan/libbluray), rubberband (breakfastquay/rubberband), libmysofa (hoene/libmysofa), chromaprint (acoustid/chromaprint), frei0r (dyne/frei0r), librist (xiph/librist), codec2 (drowe67/codec2), libgme (libgme/game-music-emu), libsnappy (google/snappy), libilbc (nicoboss/libilbc), speex (xiph/speex)

## Non-Goals

- No Windows/MSYS2 support (mediaforge is Linux/macOS only)
- No standalone tool builds (mp4box, mplayer, mpv, sox) — FFmpeg only
- No libvmaf (requires large model files, complex build)
- No libcdio (CD-ROM access, rarely needed for FFmpeg encoding)
