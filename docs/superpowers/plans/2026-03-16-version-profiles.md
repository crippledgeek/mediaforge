# Version Profiles Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add version profiles so users can build any of 4 FFmpeg releases (6.1, 7.0, 7.1, 8.0.1) with pinned dependency versions, and check for upstream updates via the GitHub API.

**Architecture:** Profile `.conf` files are shell-sourced before the recipe loop, setting `PKG_VERSION_*` environment variables. Recipes use `${PKG_VERSION_X:-default}` parameter expansion so they fall back to hardcoded values when no profile is loaded. A new `lib/updates.sh` iterates recipes and queries GitHub for latest release tags.

**Tech Stack:** POSIX sh, curl, GitHub REST API

**Spec:** `docs/superpowers/specs/2026-03-16-version-profiles-design.md`

---

## Chunk 1: Framework and CLI

### Task 1: Add `--profile`, `--list-profiles`, and `--check-updates` CLI flags

**Files:**
- Modify: `mediaforge.sh:30-37` (add variables)
- Modify: `mediaforge.sh:63-128` (add case branches)
- Modify: `mediaforge.sh:130-138` (add profile loading + action dispatch)
- Modify: `mediaforge.sh:39-55` (update usage text)

- [ ] **Step 1: Add new variables after existing feature flags (line 37)**

After `AUTOINSTALL=""` add:

```sh
PROFILE_NAME=""
CHECK_UPDATES=false
LIST_PROFILES=false
```

- [ ] **Step 2: Add case branches in the CLI parser (inside the `while` loop)**

Before the `*)` catch-all case, add:

```sh
    --profile)
      shift
      PROFILE_NAME="$1"
      ;;
    --list-profiles)
      LIST_PROFILES=true
      ;;
    --check-updates)
      CHECK_UPDATES=true
      ;;
```

- [ ] **Step 3: Add profile loading and standalone action dispatch BEFORE the `bflag` check**

After the `shift; done` loop ends (line 128) and BEFORE the `if [ -z "$bflag" ]` check (line 131), insert the following block. This ensures `--profile`, `--list-profiles`, and `--check-updates` work without requiring `-b`:

```sh
# Load version profile if specified
if [ -n "$PROFILE_NAME" ]; then
  _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
  if [ ! -f "$_profile_file" ]; then
    die "Profile not found: $_profile_file"
  fi
  . "$_profile_file"
  log "Using profile: ffmpeg-${PROFILE_NAME}"
fi

# Standalone actions (no -b required)
if [ "$LIST_PROFILES" = true ]; then
  log "Available profiles:"
  for _pf in "$SCRIPT_DIR"/profiles/ffmpeg-*.conf; do
    [ -f "$_pf" ] || continue
    _pname=$(basename "$_pf" .conf | sed 's/^ffmpeg-//')
    log "  ffmpeg-${_pname}"
  done
  exit 0
fi

if [ "$CHECK_UPDATES" = true ]; then
  . "$SCRIPT_DIR/lib/updates.sh"
  check_updates
  exit 0
fi
```

Note: `lib/updates.sh` is sourced inline only when `--check-updates` is used — it is NOT added to the top-level library sourcing section, since it is only needed for this one command.

- [ ] **Step 4: Update usage text**

Add these lines to the `usage()` function after `--auto-install`:

```sh
  printf '      --profile <name>           Use version profile (e.g., 7.1, 8.0.1)\n'
  printf '      --list-profiles            List available version profiles\n'
  printf '      --check-updates            Check for newer dependency versions on GitHub\n'
```

- [ ] **Step 5: Validate syntax**

Run: `sh -n mediaforge.sh`
Expected: no output (clean parse)

- [ ] **Step 6: Commit**

```bash
git add mediaforge.sh
git commit -m "Add --profile, --list-profiles, --check-updates CLI flags"
```

---

### Task 2: Create `lib/updates.sh` — GitHub update checker

**Files:**
- Create: `lib/updates.sh`

- [ ] **Step 1: Write `lib/updates.sh`**

```sh
#!/bin/sh
# GitHub-based dependency update checker

# Strip common tag prefixes to get bare version string
# e.g., "v1.2.3" -> "1.2.3", "n8.0.1" -> "8.0.1", "release-1.0" -> "1.0"
_strip_tag_prefix() {
  printf '%s\n' "$1" | sed -e 's/^v//' -e 's/^n//' -e 's/^release-//' -e 's/^R//'
}

# Query GitHub API for the latest release tag of a repo
# Returns stripped version string, or empty string on failure
_github_latest() {
  _repo="$1"
  _auth_header=""
  if [ -n "$GITHUB_TOKEN" ]; then
    _auth_header="Authorization: Bearer $GITHUB_TOKEN"
  fi

  _response=$(curl -sf -H "Accept: application/vnd.github.v3+json" \
    ${_auth_header:+-H "$_auth_header"} \
    "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null)

  if [ -z "$_response" ]; then
    # Try tags endpoint as fallback (some repos don't use releases)
    _response=$(curl -sf -H "Accept: application/vnd.github.v3+json" \
      ${_auth_header:+-H "$_auth_header"} \
      "https://api.github.com/repos/${_repo}/tags?per_page=1" 2>/dev/null)
    if [ -n "$_response" ]; then
      _tag=$(printf '%s\n' "$_response" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      _strip_tag_prefix "$_tag"
      return
    fi
    return 1
  fi

  _tag=$(printf '%s\n' "$_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$_tag" ]; then
    _strip_tag_prefix "$_tag"
  fi
}

# Main update check — iterates _order.conf, sources each recipe, queries GitHub
check_updates() {
  _profile_label="no profile — using recipe defaults"
  if [ -n "$PROFILE_NAME" ]; then
    _profile_label="profile: ffmpeg-${PROFILE_NAME}"
  fi

  printf 'Version Check (%s)\n' "$_profile_label"
  printf '%-20s %-15s %-15s %s\n' "Package" "Current" "Latest" "Status"
  printf '%-20s %-15s %-15s %s\n' "-------" "-------" "------" "------"

  _updates_found=0

  while IFS= read -r _recipe || [ -n "$_recipe" ]; do
    case "$_recipe" in
      ""|\#*) continue ;;
    esac

    _recipe_path="$SCRIPT_DIR/$_recipe"
    [ -f "$_recipe_path" ] || continue

    # Reset and source recipe to get its variables
    reset_recipe
    . "$_recipe_path"

    if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
      continue
    fi

    if [ -z "$PKG_GITHUB_REPO" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$PKG_VERSION" "N/A" "(not on GitHub)"
      continue
    fi

    _latest=$(_github_latest "$PKG_GITHUB_REPO")
    if [ -z "$_latest" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$PKG_VERSION" "error" "(API query failed)"
      continue
    fi

    _current=$(_strip_tag_prefix "$PKG_VERSION")
    if [ "$_current" = "$_latest" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$_current" "$_latest" "up to date"
    else
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$_current" "$_latest" "UPDATE AVAILABLE"
      _updates_found=$((_updates_found + 1))
    fi
  done < "$SCRIPT_DIR/recipes/_order.conf"

  printf '\n'
  if [ "$_updates_found" -gt 0 ]; then
    printf '%d update(s) available.\n' "$_updates_found"
  else
    printf 'All packages are up to date.\n'
  fi
}
```

- [ ] **Step 2: Validate syntax**

Run: `sh -n lib/updates.sh`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add lib/updates.sh
git commit -m "Add lib/updates.sh for GitHub-based update checking"
```

---

## Chunk 2: Recipe Changes

### Task 3: Update all recipe `PKG_VERSION` lines to use profile variables

**Files:**
- Modify: All ~50 files in `recipes/{tools,crypto,video,audio,image,hwaccel,other}/*.sh`

Each recipe's `PKG_VERSION="X"` line becomes `PKG_VERSION="${PKG_VERSION_NAME:-X}"`. The variable name is derived from the recipe filename: strip `.sh`, replace hyphens with underscores, uppercase.

Additionally, add `PKG_GITHUB_REPO="owner/repo"` to each recipe hosted on GitHub.

Below is the complete change for every recipe, grouped by category.

- [ ] **Step 1: Update `recipes/tools/` recipes (10 files)**

`recipes/tools/giflib.sh`:
```sh
PKG_VERSION="${PKG_VERSION_GIFLIB:-5.2.2}"
```
No GitHub repo (hosted on voidlinux sources). No `PKG_GITHUB_REPO` needed — `reset_recipe()` already sets it to `""`.

`recipes/tools/pkg-config.sh`:
```sh
PKG_VERSION="${PKG_VERSION_PKG_CONFIG:-0.29.2}"
```
No GitHub repo (freedesktop.org).

`recipes/tools/yasm.sh`:
```sh
PKG_VERSION="${PKG_VERSION_YASM:-1.3.0}"
PKG_GITHUB_REPO="yasm/yasm"
```

`recipes/tools/nasm.sh`:
```sh
PKG_VERSION="${PKG_VERSION_NASM:-2.16.01}"
```
No GitHub repo (nasm.us).

`recipes/tools/zlib.sh`:
```sh
PKG_VERSION="${PKG_VERSION_ZLIB:-1.3.1}"
PKG_GITHUB_REPO="madler/zlib"
```

`recipes/tools/m4.sh`:
```sh
PKG_VERSION="${PKG_VERSION_M4:-1.4.19}"
```
No GitHub repo (GNU mirror).

`recipes/tools/autoconf.sh`:
```sh
PKG_VERSION="${PKG_VERSION_AUTOCONF:-2.72}"
```
No GitHub repo (GNU mirror).

`recipes/tools/automake.sh`:
```sh
PKG_VERSION="${PKG_VERSION_AUTOMAKE:-1.17}"
```
No GitHub repo (GNU mirror).

`recipes/tools/libtool.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBTOOL:-2.4.7}"
```
No GitHub repo (GNU mirror).

`recipes/tools/cmake.sh`:
```sh
PKG_VERSION="${PKG_VERSION_CMAKE:-3.31.7}"
PKG_GITHUB_REPO="Kitware/CMake"
```

- [ ] **Step 2: Update `recipes/crypto/` recipes (4 files)**

`recipes/crypto/openssl.sh`:
```sh
PKG_VERSION="${PKG_VERSION_OPENSSL:-3.5.4}"
PKG_GITHUB_REPO="openssl/openssl"
```

`recipes/crypto/gmp.sh`:
```sh
PKG_VERSION="${PKG_VERSION_GMP:-6.3.0}"
```
No GitHub repo (GNU mirror).

`recipes/crypto/nettle.sh`:
```sh
PKG_VERSION="${PKG_VERSION_NETTLE:-3.10.2}"
```
No GitHub repo (GNU mirror).

`recipes/crypto/gnutls.sh`:
```sh
PKG_VERSION="${PKG_VERSION_GNUTLS:-3.8.11}"
```
No GitHub repo (gnupg.org).

- [ ] **Step 3: Update `recipes/video/` recipes (10 files)**

`recipes/video/dav1d.sh`:
```sh
PKG_VERSION="${PKG_VERSION_DAV1D:-1.5.3}"
```
No GitHub repo (code.videolan.org GitLab).

`recipes/video/svtav1.sh`:
```sh
PKG_VERSION="${PKG_VERSION_SVTAV1:-3.1.2}"
```
No GitHub repo (gitlab.com/AOMediaCodec).

`recipes/video/rav1e.sh`:
```sh
PKG_VERSION="${PKG_VERSION_RAV1E:-0.8.1}"
PKG_GITHUB_REPO="xiph/rav1e"
```

`recipes/video/x264.sh`:
```sh
PKG_VERSION="${PKG_VERSION_X264:-0480cb05}"
```
No GitHub repo (code.videolan.org GitLab).

`recipes/video/x265.sh`:
```sh
PKG_VERSION="${PKG_VERSION_X265:-4.1}"
```
No GitHub repo (bitbucket.org).

`recipes/video/libvpx.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBVPX:-1.15.2}"
PKG_GITHUB_REPO="webmproject/libvpx"
```

`recipes/video/xvidcore.sh`:
```sh
PKG_VERSION="${PKG_VERSION_XVIDCORE:-1.3.7}"
```
No GitHub repo (xvid.com).

`recipes/video/vid_stab.sh`:
```sh
PKG_VERSION="${PKG_VERSION_VID_STAB:-1.1.1}"
PKG_GITHUB_REPO="georgmartius/vid.stab"
```

`recipes/video/av1.sh`:
```sh
PKG_VERSION="${PKG_VERSION_AV1:-d772e334cc724105040382a977ebb10dfd393293}"
```
No GitHub repo (googlesource.com). Note: commit hash, not semver.

`recipes/video/zimg.sh`:
```sh
PKG_VERSION="${PKG_VERSION_ZIMG:-3.0.6}"
PKG_GITHUB_REPO="sekrit-twc/zimg"
```

- [ ] **Step 4: Update `recipes/audio/` recipes (9 files)**

`recipes/audio/lv2.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LV2:-1.18.10}"
```
No GitHub repo (lv2plug.in).

`recipes/audio/opencore.sh`:
```sh
PKG_VERSION="${PKG_VERSION_OPENCORE:-0.1.6}"
```
No GitHub repo (sourceforge).

`recipes/audio/lame.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LAME:-3.100}"
```
No GitHub repo (sourceforge).

`recipes/audio/opus.sh`:
```sh
PKG_VERSION="${PKG_VERSION_OPUS:-1.6}"
```
No GitHub repo (xiph.org).

`recipes/audio/libogg.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBOGG:-1.3.6}"
```
No GitHub repo (xiph.org).

`recipes/audio/libvorbis.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBVORBIS:-1.3.7}"
```
No GitHub repo (xiph.org).

`recipes/audio/libtheora.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBTHEORA:-1.2.0}"
```
No GitHub repo (xiph.org).

`recipes/audio/fdk_aac.sh`:
```sh
PKG_VERSION="${PKG_VERSION_FDK_AAC:-2.0.3}"
```
No GitHub repo (sourceforge).

`recipes/audio/soxr.sh`:
```sh
PKG_VERSION="${PKG_VERSION_SOXR:-0.1.3}"
```
No GitHub repo (sourceforge).

- [ ] **Step 5: Update `recipes/image/` recipes (4 files)**

`recipes/image/libtiff.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBTIFF:-4.7.1}"
```
No GitHub repo (osgeo.org).

`recipes/image/libpng.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBPNG:-1.6.53}"
```
No GitHub repo (sourceforge).

`recipes/image/libjxl.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBJXL:-0.11.1}"
PKG_GITHUB_REPO="libjxl/libjxl"
```

`recipes/image/libwebp.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBWEBP:-1.6.0}"
PKG_GITHUB_REPO="webmproject/libwebp"
```

- [ ] **Step 6: Update `recipes/hwaccel/` recipes (6 files)**

`recipes/hwaccel/vulkan-headers.sh`:
```sh
PKG_VERSION="${PKG_VERSION_VULKAN_HEADERS:-1.4.338}"
PKG_GITHUB_REPO="KhronosGroup/Vulkan-Headers"
```

`recipes/hwaccel/glslang.sh`:
```sh
PKG_VERSION="${PKG_VERSION_GLSLANG:-16.1.0}"
PKG_GITHUB_REPO="KhronosGroup/glslang"
```

`recipes/hwaccel/nv-codec.sh`:
```sh
PKG_VERSION="${PKG_VERSION_NV_CODEC:-11.1.5.3}"
PKG_GITHUB_REPO="FFmpeg/nv-codec-headers"
```

`recipes/hwaccel/vaapi.sh`:
```sh
PKG_VERSION="${PKG_VERSION_VAAPI:-1}"
```
No GitHub repo (system-detected, sentinel version).

`recipes/hwaccel/amf.sh`:
```sh
PKG_VERSION="${PKG_VERSION_AMF:-1.5.0}"
PKG_GITHUB_REPO="GPUOpen-LibrariesAndSDKs/AMF"
```

`recipes/hwaccel/opencl.sh`:
```sh
PKG_VERSION="${PKG_VERSION_OPENCL:-2025.07.22}"
PKG_GITHUB_REPO="KhronosGroup/OpenCL-Headers"
```

- [ ] **Step 7: Update `recipes/other/` recipes (7 files)**

`recipes/other/gettext.sh`:
```sh
PKG_VERSION="${PKG_VERSION_GETTEXT:-0.22.5}"
```
No GitHub repo (GNU mirror).

`recipes/other/libsdl.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBSDL:-2.32.10}"
PKG_GITHUB_REPO="libsdl-org/SDL"
```

`recipes/other/freetype2.sh`:
```sh
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
```
No GitHub repo (sourceforge).

`recipes/other/vapoursynth.sh`:
```sh
PKG_VERSION="${PKG_VERSION_VAPOURSYNTH:-73}"
PKG_GITHUB_REPO="vapoursynth/vapoursynth"
```

`recipes/other/srt.sh`:
```sh
PKG_VERSION="${PKG_VERSION_SRT:-1.5.4}"
PKG_GITHUB_REPO="Haivision/srt"
```

`recipes/other/zvbi.sh`:
```sh
PKG_VERSION="${PKG_VERSION_ZVBI:-0.2.44}"
PKG_GITHUB_REPO="zapping-vbi/zvbi"
```

`recipes/other/libzmq.sh`:
```sh
PKG_VERSION="${PKG_VERSION_LIBZMQ:-4.3.5}"
PKG_GITHUB_REPO="zeromq/libzmq"
```

- [ ] **Step 8: Add `PKG_GITHUB_REPO` to `reset_recipe()` in `lib/framework.sh`**

Add after `PKG_CMAKE_FLAGS=""` in `reset_recipe()`:

```sh
  PKG_GITHUB_REPO=""
```

- [ ] **Step 9: Validate all recipe syntax**

Run: `for f in recipes/**/*.sh recipes/*.sh; do sh -n "$f" || echo "FAIL: $f"; done`
Expected: no output

- [ ] **Step 10: Validate framework syntax**

Run: `sh -n lib/framework.sh`
Expected: no output

- [ ] **Step 11: Commit**

```bash
git add recipes/ lib/framework.sh
git commit -m "Update all recipes to support profile version overrides

Each recipe's PKG_VERSION now uses \${PKG_VERSION_NAME:-default}
parameter expansion. Adds PKG_GITHUB_REPO to GitHub-hosted recipes
for --check-updates support."
```

---

## Chunk 3: Profile Files

### Task 4: Create `profiles/ffmpeg-8.0.1.conf`

**Files:**
- Create: `profiles/ffmpeg-8.0.1.conf`

This profile is extracted directly from the current hardcoded values in every recipe.

- [ ] **Step 1: Create the profile file**

```sh
# FFmpeg 8.0.1 Build Profile
# Compatible dependency versions verified against this FFmpeg release
# Generated from hardcoded recipe defaults — 2026-03-16

# ── FFmpeg ──
FFMPEG_VERSION="8.0.1"

# ── Build Tools ──
PKG_VERSION_GIFLIB="5.2.2"
PKG_VERSION_PKG_CONFIG="0.29.2"
PKG_VERSION_YASM="1.3.0"
PKG_VERSION_NASM="2.16.01"
PKG_VERSION_ZLIB="1.3.1"
PKG_VERSION_M4="1.4.19"
PKG_VERSION_AUTOCONF="2.72"
PKG_VERSION_AUTOMAKE="1.17"
PKG_VERSION_LIBTOOL="2.4.7"
PKG_VERSION_CMAKE="3.31.7"

# ── Crypto ──
# openssl path (--nonfree) and gnutls path are mutually exclusive
PKG_VERSION_OPENSSL="3.5.4"
PKG_VERSION_GMP="6.3.0"
PKG_VERSION_NETTLE="3.10.2"
PKG_VERSION_GNUTLS="3.8.11"

# ── Video Codecs ──
PKG_VERSION_DAV1D="1.5.3"
PKG_VERSION_SVTAV1="3.1.2"
PKG_VERSION_RAV1E="0.8.1"
PKG_VERSION_X264="0480cb05"
PKG_VERSION_X265="4.1"
PKG_VERSION_LIBVPX="1.15.2"
PKG_VERSION_XVIDCORE="1.3.7"
PKG_VERSION_VID_STAB="1.1.1"
PKG_VERSION_AV1="d772e334cc724105040382a977ebb10dfd393293"
PKG_VERSION_ZIMG="3.0.6"

# ── Audio Codecs ──
PKG_VERSION_LV2="1.18.10"
PKG_VERSION_OPENCORE="0.1.6"
PKG_VERSION_LAME="3.100"
PKG_VERSION_OPUS="1.6"
PKG_VERSION_LIBOGG="1.3.6"
PKG_VERSION_LIBVORBIS="1.3.7"
PKG_VERSION_LIBTHEORA="1.2.0"
PKG_VERSION_FDK_AAC="2.0.3"
PKG_VERSION_SOXR="0.1.3"

# ── Image Libraries ──
PKG_VERSION_LIBTIFF="4.7.1"
PKG_VERSION_LIBPNG="1.6.53"
PKG_VERSION_LIBJXL="0.11.1"
PKG_VERSION_LIBWEBP="1.6.0"

# ── Other Libraries ──
PKG_VERSION_GETTEXT="0.22.5"
PKG_VERSION_LIBSDL="2.32.10"
PKG_VERSION_FREETYPE2="2.14.1"
PKG_VERSION_VAPOURSYNTH="73"
PKG_VERSION_SRT="1.5.4"
PKG_VERSION_ZVBI="0.2.44"
PKG_VERSION_LIBZMQ="4.3.5"

# ── HW Acceleration ──
PKG_VERSION_VULKAN_HEADERS="1.4.338"
PKG_VERSION_GLSLANG="16.1.0"
PKG_VERSION_NV_CODEC="11.1.5.3"
PKG_VERSION_VAAPI="1"    # sentinel — system-detected, not downloaded
PKG_VERSION_AMF="1.5.0"
PKG_VERSION_OPENCL="2025.07.22"
```

- [ ] **Step 2: Validate syntax**

Run: `sh -n profiles/ffmpeg-8.0.1.conf`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add profiles/ffmpeg-8.0.1.conf
git commit -m "Add profiles/ffmpeg-8.0.1.conf — current version profile"
```

---

### Task 5: Research and create older version profiles

**Files:**
- Create: `profiles/ffmpeg-7.1.conf`
- Create: `profiles/ffmpeg-7.0.conf`
- Create: `profiles/ffmpeg-6.1.conf`

This task requires online research to determine compatible dependency versions for each FFmpeg release. The approach:

1. Find FFmpeg release dates (6.1: Nov 2023, 7.0: Apr 2024, 7.1: Sep 2024)
2. For each dependency, find the version that was current/latest at that FFmpeg release date
3. Cross-reference FFmpeg `configure` output and changelog for any known compatibility requirements

- [ ] **Step 1: Research compatible versions for FFmpeg 7.1 (released ~Sep 2024)**

Use web search and GitHub release pages to find dependency versions contemporary with Sep 2024. Create `profiles/ffmpeg-7.1.conf` with the same structure as 8.0.1.

- [ ] **Step 2: Research compatible versions for FFmpeg 7.0 (released ~Apr 2024)**

Create `profiles/ffmpeg-7.0.conf`.

- [ ] **Step 3: Research compatible versions for FFmpeg 6.1 (released ~Nov 2023)**

Create `profiles/ffmpeg-6.1.conf`.

- [ ] **Step 4: Validate all profile syntax**

Run: `for f in profiles/*.conf; do sh -n "$f" || echo "FAIL: $f"; done`
Expected: no output

- [ ] **Step 5: Commit**

```bash
git add profiles/ffmpeg-7.1.conf profiles/ffmpeg-7.0.conf profiles/ffmpeg-6.1.conf
git commit -m "Add version profiles for FFmpeg 7.1, 7.0, and 6.1

Dependency versions researched to match each FFmpeg release date
for build compatibility."
```

---

## Chunk 4: Validation and Documentation

### Task 6: Full syntax validation and final commit

**Files:**
- Validate: all `.sh` and `.conf` files

- [ ] **Step 1: Run full syntax check**

```bash
sh -n mediaforge.sh
for f in lib/*.sh; do sh -n "$f"; done
for f in recipes/**/*.sh recipes/*.sh; do sh -n "$f"; done
for f in profiles/*.conf; do sh -n "$f"; done
```

Expected: all pass with no output.

- [ ] **Step 2: Verify backward compatibility**

Confirm that without `--profile`, every recipe `PKG_VERSION` resolves to its hardcoded default. Spot-check by grepping for a few recipes:

```bash
grep 'PKG_VERSION=' recipes/video/dav1d.sh
# Expected: PKG_VERSION="${PKG_VERSION_DAV1D:-1.5.3}"

grep 'PKG_VERSION=' recipes/tools/cmake.sh
# Expected: PKG_VERSION="${PKG_VERSION_CMAKE:-3.31.7}"
```

- [ ] **Step 3: Verify `--list-profiles` output**

```bash
sh mediaforge.sh --list-profiles
```

Expected: lists all 4 profiles.

- [ ] **Step 4: Update CLAUDE.md**

Add version profiles to the Commands section:

```sh
# Build with a specific FFmpeg version profile
./mediaforge.sh -b --profile 7.1

# List available version profiles
./mediaforge.sh --list-profiles

# Check for dependency updates on GitHub
./mediaforge.sh --check-updates
./mediaforge.sh --check-updates --profile 7.1
```

- [ ] **Step 5: Commit CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "Document version profile commands in CLAUDE.md"
```
