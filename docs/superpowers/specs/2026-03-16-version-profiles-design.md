# Version Profiles Design

## Problem

All ~50 dependency versions are hardcoded in individual recipe files and `FFMPEG_VERSION` is hardcoded in `mediaforge.sh`. Upgrading FFmpeg or testing against an older release requires manually editing dozens of files. There is no way to reproduce a known-good build configuration or compare current versions against upstream releases.

## Solution

Introduce version profiles — structured configuration files that pin every dependency version for a given FFmpeg release. Recipes read profile-provided versions with fallback to their hardcoded defaults. A new `--check-updates` command queries the GitHub API to report available upgrades.

## Profile File Format

Profile files live in `profiles/` named `ffmpeg-X.Y.Z.conf`. They are shell-sourceable `KEY=VALUE` files organized by category with comments.

Variable naming convention: `PKG_VERSION_<UPPER_SNAKE_NAME>` derived from the recipe filename by stripping the `.sh` extension, replacing hyphens with underscores, and converting to uppercase (e.g., `fdk_aac.sh` → `PKG_VERSION_FDK_AAC`, `vulkan-headers.sh` → `PKG_VERSION_VULKAN_HEADERS`, `nv-codec.sh` → `PKG_VERSION_NV_CODEC`).

Example:

```sh
# FFmpeg 8.0.1 Build Profile
# Compatible dependency versions verified against this FFmpeg release

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
PKG_VERSION_VAAPI="1"  # sentinel — vaapi is system-detected, not downloaded
PKG_VERSION_AMF="1.5.0"
PKG_VERSION_OPENCL="2025.07.22"
```

## Recipe Changes

Each recipe changes one line. The hardcoded `PKG_VERSION` becomes a parameter expansion with the current value as fallback:

Before:

```sh
PKG_VERSION="1.5.3"
```

After:

```sh
PKG_VERSION="${PKG_VERSION_DAV1D:-1.5.3}"
```

This preserves backward compatibility — without a profile loaded, every recipe behaves identically to today.

Additionally, each recipe with a GitHub-hosted source gains an optional variable for update checking:

```sh
PKG_GITHUB_REPO="videolan/dav1d"
```

Recipes without `PKG_GITHUB_REPO` are skipped by `--check-updates`.

## Framework Changes

### CLI Flags (mediaforge.sh)

Three new flags added to the CLI parser:

| Flag | Argument | Behavior |
|---|---|---|
| `--profile` | `<name>` | Load `profiles/ffmpeg-<name>.conf` before recipe loop |
| `--list-profiles` | none | List available profiles from `profiles/` directory, then exit |
| `--check-updates` | none | Compare current versions against GitHub latest releases, then exit |

### Profile Loading

After CLI parsing, before the `_order.conf` recipe loop:

```sh
if [ -n "$PROFILE_NAME" ]; then
    _profile_file="$CWD/profiles/ffmpeg-${PROFILE_NAME}.conf"
    if [ ! -f "$_profile_file" ]; then
        die "Profile not found: $_profile_file"
    fi
    . "$_profile_file"
    log "Using profile: ffmpeg-${PROFILE_NAME}"
fi
```

The profile is sourced into the current shell environment. All `PKG_VERSION_*` variables become available to recipes via the `${PKG_VERSION_X:-default}` expansion.

`FFMPEG_VERSION` is overridden directly by the profile via reassignment (not `${VAR:-default}` expansion). This is intentional — unlike recipe versions, `FFMPEG_VERSION` is set in `mediaforge.sh` line 4 and the profile unconditionally overwrites it. If a custom profile omits `FFMPEG_VERSION`, the hardcoded value from `mediaforge.sh` is used silently.

### `--latest` Behavior

Unchanged. When `--latest` is set (`LATEST=true`), the `build()` function in `lib/utils.sh` allows rebuilding packages whose `.done` file version differs from the current `PKG_VERSION`. Without `--latest`, version mismatches are logged but the package is skipped. Note: `--latest` does NOT clear `.done` files — it changes the conditional logic in `build()` to return 0 (proceed) instead of 1 (skip) on version mismatch.

Profile-pinned versions are still respected — `--latest` means "rebuild outdated packages" not "use newest upstream versions."

### Profile Switching Workflow

When switching between profiles (e.g., from 8.0.1 to 7.1), packages with different pinned versions will have stale `.done` files containing the old version. The `build()` function detects the mismatch. Users must pass `--latest` to trigger rebuilds of changed packages:

```sh
# Switch from 8.0.1 to 7.1 — needs --latest to rebuild changed deps
./mediaforge.sh -b --profile 7.1 --latest
```

Without `--latest`, mismatched packages are logged as outdated but skipped.

### `--list-profiles`

Scans `profiles/` for `ffmpeg-*.conf` files, extracts the FFmpeg version from each, and prints a list:

```
Available profiles:
  ffmpeg-8.0.1  (default: current hardcoded versions)
  ffmpeg-7.1
  ffmpeg-7.0
  ffmpeg-6.1
```

## Update Checking

### New File: lib/updates.sh

Contains the `check_updates` function. Iterates `_order.conf`, sources each recipe (via `reset_recipe` + `. recipe`) to read `PKG_NAME`, `PKG_VERSION`, and `PKG_GITHUB_REPO`. License guards are ignored — all packages appear in the report regardless of `--gpl`/`--nonfree` flags. For each recipe that defines `PKG_GITHUB_REPO`, queries the GitHub API (`https://api.github.com/repos/<owner>/<repo>/releases/latest`).

Compares the latest release tag against the current `PKG_VERSION` (from profile or recipe default) and prints a report:

When no profile is specified, the header reads `(no profile — using recipe defaults)`.

```
Version Check (profile: ffmpeg-8.0.1)
──────────────────────────────────────
Package          Current    Latest     Status
dav1d            1.5.3      1.5.3      up to date
x265             4.1        4.2        UPDATE AVAILABLE
libvpx           1.15.2     1.16.0     UPDATE AVAILABLE
opus             1.6        1.6        up to date
openssl          3.5.4      3.5.5      UPDATE AVAILABLE
cmake            3.31.7     3.31.7     up to date
libjxl           0.11.1     0.12.0     UPDATE AVAILABLE
lv2              1.18.10    N/A        (not on GitHub)
lame             3.100      N/A        (not on GitHub)
...
```

### Implementation Constraints

- Uses `curl` to query GitHub API (already a de facto dependency for downloading sources)
- Respects GitHub rate limits (unauthenticated: 60 requests/hour). With ~35 GitHub-hosted packages this is within limits for a single run.
- Tag parsing strips common prefixes (`v`, `n`, `release-`) to normalize version comparison
- No authentication required. If `GITHUB_TOKEN` is set in the environment, it is passed as a bearer token for higher rate limits.
- Non-GitHub packages (sourceforge, GNU mirrors, xiph.org) show "N/A" — no scraping

## Profiles to Ship

| Profile | FFmpeg | Notes |
|---|---|---|
| `ffmpeg-8.0.1.conf` | 8.0.1 | Extracted from current hardcoded versions |
| `ffmpeg-7.1.conf` | 7.1 | Latest 7.x — requires research for compatible dep versions |
| `ffmpeg-7.0.conf` | 7.0 | First 7.x — requires research for compatible dep versions |
| `ffmpeg-6.1.conf` | 6.1 | Last 6.x LTS — requires research for compatible dep versions |

The `ffmpeg-8.0.1.conf` profile is derived directly from today's hardcoded values. Older profiles require researching which dependency versions were compatible with each FFmpeg release (checking FFmpeg release dates and finding dependency versions current at that time).

## Backward Compatibility

- No `--profile` flag: recipes use hardcoded defaults. Behavior is identical to today.
- `--profile` flag: profile overrides recipe defaults via environment variables.
- Existing CLI flags (`--gpl`, `--nonfree`, `--full-static`, `--latest`) work identically with or without a profile.
- Recipe guards (`PKG_GPL`, `PKG_NONFREE`, `PKG_SKIP_IF_NONFREE`, etc.) are unaffected — they control whether a recipe runs, not what version it uses.

## Files Changed

| File | Change |
|---|---|
| `mediaforge.sh` | Add `--profile`, `--list-profiles`, `--check-updates` CLI parsing + profile sourcing logic |
| `lib/updates.sh` | New file — GitHub API update checking |
| All ~50 `recipes/**/*.sh` | One-line `PKG_VERSION` change + optional `PKG_GITHUB_REPO` |
| `profiles/ffmpeg-8.0.1.conf` | New file — current versions extracted |
| `profiles/ffmpeg-7.1.conf` | New file — researched compatible versions |
| `profiles/ffmpeg-7.0.conf` | New file — researched compatible versions |
| `profiles/ffmpeg-6.1.conf` | New file — researched compatible versions |

## Profile Validation

Profile files are sourced directly into the shell via `. "$_profile_file"`. Since profiles are user-controlled files shipped with the project, no runtime sandboxing is applied. Profiles should be validated with `sh -n` (consistent with the project's existing validation approach for shell files) before committing.

## Not in Scope

- Per-package CLI version overrides
- Automatic profile generation tooling
- Non-GitHub version checking (sourceforge, GNU mirrors)
- Profile validation / compatibility testing
