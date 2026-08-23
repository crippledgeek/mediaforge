# mediaforge

A POSIX shell build system that compiles FFmpeg from source with ~80 modular dependency recipes. Supports multiple FFmpeg versions via build profiles.

## Features

- **~80 modular recipes** — each dependency is a self-contained shell file
- **64 enabled FFmpeg features** — video, audio, subtitle, image, streaming, HW acceleration
- **Version profiles** — pin all dependency versions per FFmpeg release (8.0.1, 7.1, 7.0, 6.1)
- **License tiers** — free, GPL, and non-free codec selection
- **Cross-platform** — Linux and macOS (including Apple Silicon)
- **Full static binaries** — optional fully static build on Linux
- **Install/uninstall** — manifest-tracked installation of binaries, libraries, and headers
- **Update checker** — compare installed versions against GitHub releases
- **Zero system pollution** — all build artifacts are isolated until explicit install

## Requirements

### Required

| Dependency | Purpose |
|------------|---------|
| POSIX shell | `sh`, `dash`, `bash`, or `zsh` |
| `make` | Build system |
| `g++` | C/C++ compiler (Linux). On macOS, `clang++` via Xcode is used instead |
| `curl` | Downloading source tarballs |

### Optional

These enable additional codecs. If missing, the corresponding recipes are skipped automatically with a warning.

| Dependency | Enables |
|------------|---------|
| `cargo` | rav1e (AV1 encoder) |
| `python3` | dav1d, lv2, glslang |
| `meson` + `ninja` | dav1d, lv2, fribidi, harfbuzz, fontconfig, openh264, rubberband, librist |
| `nvcc` (CUDA toolkit) | NVIDIA CUDA filters (nvenc/nvdec work without it) |
| `git` | librtmp (cloned from git.ffmpeg.org, no tarball available) |

Install optional dependencies on Arch Linux:

```sh
sudo pacman -S rust python meson ninja cuda
```

On Ubuntu/Debian:

```sh
sudo apt install cargo python3 meson ninja-build nvidia-cuda-toolkit
```

## Quick Start

```sh
# Build FFmpeg with free codecs
./mediaforge.sh build

# Build with GPL codecs (x264, x265, xvidcore, vid.stab)
./mediaforge.sh build --enable-gpl

# Build with GPL + non-free codecs (adds openssl, fdk-aac)
./mediaforge.sh build --enable-nonfree

# Full static binary with all codecs
./mediaforge.sh build --enable-nonfree --enable-static
```

> **Note — `build` installs when it finishes.** By default the `build` command
> runs the install step at the end, which prompts with the interactive prefix
> menu (System / User / custom). Pass `-I` / `--no-install` to build *only* and
> install later as a separate step. The `--prefix=` flag applies to the
> standalone `install` command, not to `build`'s trailing auto-install (that
> one always uses the menu).
>
> ```sh
> ./mediaforge.sh build --enable-nonfree --enable-static --no-install
> ./mediaforge.sh install --prefix=$HOME/.local/mediaforge
> ```

## Usage

```
Usage: mediaforge.sh <command> [options]

Commands:
  build              Build FFmpeg and dependencies
  clean              Remove all build artifacts
  install            Install built binaries and libraries
  uninstall          Remove installed files
  check-updates      Check for newer dependency versions
  check-shadowers    Audit workspace .pc files for system-version shadowing
  list-profiles      List available version profiles
  help               Show help
  version            Show version

Build options:
  -g, --enable-gpl          Enable GPL-licensed codecs
  -G, --enable-nonfree      Enable non-free codecs (implies GPL)
  -L, --disable-lv2         Skip LV2 plugin chain
  -s, --enable-static       Full static binary (Linux only)
  -m, --enable-small        Minimal build
      --enable-lto          Enable LTO in recipes that support it
                            (default: off; archives may break on GCC major bumps)
      --disable-lto         Force LTO off (default)
  -p, --profile=X.Y         Use version profile
  -j, --jobs=N              Parallel job count (default: auto)
  -u, --rebuild-outdated    Rebuild stale dependencies
  -I, --no-install          Skip post-build install
  -y, --yes                 Non-interactive mode
      --menu                Interactive selector (whiptail or POSIX fallback)
  -v, --verbose             Show build commands (-vv for more)
  -q, --quiet               Errors only
  -n, --dry-run             Show what would build
  -k, --keep-going          Continue on recipe failure

Codec / backend selectors (mutually exclusive within each group):
  --tls=BACKEND             TLS backend: openssl|gnutls|mbedtls|libressl|none
                            (default: gnutls)
  --aac=IMPL                AAC encoder: fdk_aac|native
                            (default: native; nonfree -> fdk_aac)
  --h264=IMPL               H.264 encoder: x264|openh264 (default: x264)
  --h265=IMPL               H.265 encoder: x265|kvazaar (default: x265)
  --av1-enc=IMPL            AV1 encoder: svtav1|rav1e|av1 (default: svtav1)
  --flite-audio=BACKEND     flite audio output: none|alsa|pulseaudio|oss|sun
                            (default: none; FFmpeg filter does not invoke it)
  --openssldir=PATH         Compiled-in trust store for the openssl/libressl
                            arms (absolute). Default: probe the host for a
                            directory holding cert.pem, else the build prefix.

Recipe overrides:
  --disable=PKG             Disable a recipe by name (repeatable, comma-separated ok)
  --enable=PKG              Force-enable a recipe that defaults to off
  --list-pkgs               Print every recipe with category and mutex group
  --clean-choices           Delete the stored choice matrix and exit

Install/uninstall options:
  --prefix=PATH             Install/uninstall location (default: interactive prompt)
  -y, --yes                 Non-interactive mode
```

### Examples

```sh
# Build with short flags
./mediaforge.sh build -Gs                # nonfree + static
./mediaforge.sh build -g -j 4            # GPL, 4 jobs
./mediaforge.sh build -n                  # dry run

# Version profiles
./mediaforge.sh list-profiles
./mediaforge.sh build --profile=7.1
./mediaforge.sh build --profile=6.1 --rebuild-outdated

# Install/uninstall
./mediaforge.sh install                   # interactive menu
./mediaforge.sh install --prefix=/opt/ffmpeg
./mediaforge.sh install --prefix=$HOME/.local/mediaforge  # isolated user prefix
./mediaforge.sh uninstall                 # discovers installs via manifest
./mediaforge.sh uninstall --prefix=/opt/ffmpeg

# Update checking
./mediaforge.sh check-updates
./mediaforge.sh check-updates --profile=7.1
GITHUB_TOKEN=ghp_xxx ./mediaforge.sh check-updates

# Audit pkgconfig drift (after build, before release)
./mediaforge.sh check-shadowers              # warn-only, exit 0
./mediaforge.sh check-shadowers --strict     # exit 1 on new shadowers (CI)

# Clean
./mediaforge.sh clean
```

### Install doctrine: don't sudo into your own home

The installer elevates with `sudo` automatically when the target prefix
requires it (e.g. `/usr/local`). **Do not** wrap `./mediaforge.sh install`
with `sudo` yourself when targeting a user-owned prefix
(`~/.local/mediaforge`, `~/opt/...`). Files inherit the running process's
UID — running as root leaves root-owned files in your home that you
can't modify or delete without sudo on every operation.

| You are | Targeting | Run install as | Resulting ownership |
|---|---|---|---|
| user | `~/.local/mediaforge` | yourself (no sudo) | `you:you` ✓ |
| user | `/usr/local` | yourself (installer wraps `sudo`) | `root:root` ✓ |
| root | `/usr/local` | yourself | `root:root` ✓ |
| root | `/home/<user>/.local/...` | DON'T | `root:root` ✗ |

Same rule for uninstall.

### Recommended prefix for downstream-link use cases

If anything else on your system links against mediaforge (e.g. a Rust
crate consuming FFmpeg via `pkg-config`), install to an **isolated
subdirectory** rather than over the shared user/system prefix:

```sh
./mediaforge.sh install --prefix=$HOME/.local/mediaforge
```

The isolated dir keeps mediaforge's 94 workspace `.pc` files out of the shared
`~/.local/lib/pkgconfig/`. The install layer also **drops 19 specific
transitive-dep `.pc` files** that would shadow newer system versions
(`fontconfig`, `freetype2`, `harfbuzz`, `expat`, `gnutls`, `libpng`,
`bzip2`, `libxml-2.0`, `fribidi`, `gmp`, `nettle`, `hogweed`, `brotli*`,
`lzma`, `zlib`). The `.a` archives still install — FFmpeg's static link
still references their symbols — but their `.pc` files are absent from
the install prefix, so a downstream consumer's `pkg-config fontconfig`
falls through to the system's newer version.

Downstream consumers point `PKG_CONFIG_PATH` at mediaforge's prefix
first, then the system path. This is the canonical Linux side-install
pattern (Homebrew's `/opt/homebrew/`, MacPorts' `/opt/local/`, GNU stow,
NixOS profiles).

### Auditing pkgconfig drift

When you add a new recipe or want to verify the workspace doesn't ship
a new shadowing `.pc` file:

```sh
./mediaforge.sh check-shadowers
```

The command probes every `.pc` in the workspace against the system
pkgconfig path and classifies each match as `[expected]` (already in
the install-time stop-list) or `[NEW SHADOW]` (not in the stop-list —
review whether to add it). Exits 0 by default (warn-only, matches
`rpmlint`/`lintian`/`brew audit` convention); `--strict` exits 1 for
CI gating. The stop-list lives in `lib/install.sh:_PKGCONFIG_SHADOWERS`.

### TLS trust stores

What the built FFmpeg trusts for `https://` depends on which `--tls` arm you
picked, and the four arms genuinely differ:

| Arm | Default trust store | Runtime override |
|---|---|---|
| `gnutls` | Host store, found by gnutls's own configure probe | `-ca_file` |
| `openssl` | Compiled-in `OPENSSLDIR` — the probed host store, else the build prefix (which ships no certs) | `-ca_file`, `SSL_CERT_FILE`, `SSL_CERT_DIR` |
| `libressl` | Compiled-in `<openssldir>/cert.pem` | **`-ca_file` only** |
| `mbedtls` | None at all | `-ca_file` only |

`--openssldir=PATH` sets the compiled-in directory for the `openssl` and
`libressl` arms. It must be absolute: the value is baked into the library, so a
relative path would resolve against the working directory of whatever process
links it, and the arm would silently trust nothing.

Left unset, mediaforge probes the host for a directory that actually contains a
`cert.pem` (`/etc/ssl`, `/etc/pki/tls`, `/usr/local/etc/ssl`, Homebrew's
`etc/ca-certificates`) and falls back to the build prefix — the same
try-a-list-then-fall-back shape curl and gnutls use in their own configure.
Debian and Ubuntu ship `ca-certificates.crt` and no `cert.pem`, so they take the
fallback; Fedora and RHEL are matched by the `/etc/pki/tls` entry.

The `libressl` arm is the one to watch, because libtls has **no** environment
escape — it reads no `SSL_CERT_FILE`, so the compiled-in path is the only
default it will ever have, and `-ca_file` is the only way to override it at
runtime. mediaforge always stages LibreSSL's own bundled CA list into the build
prefix; `install` then places it at whichever path the build baked in, provided
that path lies inside the install prefix. So the way to get verification working
out of the box is to bake the install location at build time:

```sh
./mediaforge.sh build --tls=libressl --openssldir="$HOME/.local/mediaforge/etc/ssl"
./mediaforge.sh install --prefix="$HOME/.local/mediaforge"
```

If the baked path is left at the build prefix and you install elsewhere, the
bundle is still installed (so it survives `clean`) but *not* at the path the
binary looks in — `install` says so explicitly, and you then need `-ca_file`.

A build that resolved to a **host** trust store installs no bundle at all: that
directory is the host's to manage, and writing mediaforge's build-time snapshot
over it is exactly what `patches/libressl-no-openssldir-install.patch` exists to
prevent.

Note that the baked path is a build input the stamp does not capture, so
re-running `build` with a different `--openssldir` on an existing workspace will
**not** rebuild the TLS arm — it is skipped as already-built and keeps the old
baked path. mediaforge warns when it sees the value change and prints the stamp
to remove; it does not abort, because a stale stamp is not the only reason the
two can differ.

Unlike the other dependencies, LibreSSL is pinned to the same current version in
every version profile rather than an era-appropriate one. Holding an old
LibreSSL to match an old FFmpeg would mean shipping known upstream security
fixes back out of a build — for example the CMS enveloped-data out-of-bounds
read/write fixed in 4.2.0 — and that is not a trade a version profile should be
making on the user's behalf.

## Version Profiles

Profiles pin all ~80 dependency versions to a known-good set for a specific FFmpeg release:

| Profile | FFmpeg | Release |
|---------|--------|---------|
| `8.0.1` | 8.0.1  | 2025    |
| `7.1`   | 7.1    | Sep 2024 |
| `7.0`   | 7.0    | Apr 2024 |
| `6.1`   | 6.1    | Nov 2023 |

Without `--profile`, recipes use their built-in default versions (equivalent to the 8.0.1 profile).

## Project Structure

```
mediaforge.sh              Main driver — subcommand dispatch, recipe orchestration
lib/
  utils.sh                 Core utilities (logging, stamp gating, run)
  platform.sh              OS/arch detection (Linux, macOS, Apple Silicon)
  framework.sh             Recipe lifecycle (run_recipe, reset, guards, phases)
  download.sh              Tarball fetch with cache and exponential backoff
  cleanup.sh               Signal trap handler
  install.sh               Install/uninstall with manifest tracking
  updates.sh               GitHub API update checker
patches/
  giflib-makefile.patch     Remove doc/man build targets
  libjxl-static-linking.patch  Fix jxl_threads static linking
  libvorbis-cpusubtype.patch   Remove macOS -force_cpusubtype_ALL
  libzmq-stats-proxy.patch     GCC 15 C23 aggregate init fix
profiles/
  ffmpeg-8.0.1.conf        Version pins for FFmpeg 8.0.1
  ffmpeg-7.1.conf          Version pins for FFmpeg 7.1
  ffmpeg-7.0.conf          Version pins for FFmpeg 7.0
  ffmpeg-6.1.conf          Version pins for FFmpeg 6.1
recipes/
  _order.conf              Declarative build order
  ffmpeg.sh                Final FFmpeg build
  tools/                   Build tools (cmake, nasm, pkg-config, zlib, ...)
  crypto/                  Crypto libraries (openssl, gnutls, gmp, nettle)
  video/                   Video codecs (x264, x265, libvpx, dav1d, svtav1, ...)
  audio/                   Audio codecs (opus, lame, fdk-aac, vorbis, ...)
  image/                   Image libraries (libpng, libjxl, libwebp, ...)
  hwaccel/                 HW acceleration (vaapi, vulkan, nvcodec, opencl, ...)
  other/                   Other libraries (freetype, srt, libzmq, ...)
```

## How It Works

1. `mediaforge.sh` sources all `lib/*.sh` and dispatches the subcommand
2. `build` parses options, loads the version profile if specified
3. Iterates `recipes/_order.conf`, calling `run_recipe()` for each entry
4. Each recipe sets `PKG_*` variables and optionally overrides build phases
5. Stamp files in `workspace/.stamps/` track what's already built
6. After all recipes, accumulated flags are applied and FFmpeg is built
7. Binaries and libraries are optionally installed with manifest tracking

## Writing Recipes

Each recipe is a shell file that sets variables and optionally overrides phase functions:

```sh
PKG_NAME="mylib"
PKG_VERSION="${PKG_VERSION_MYLIB:-1.0.0}"
PKG_URL="https://example.com/mylib-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-mylib"

# Optional: override any build phase
pkg_configure() {
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static
}
```

Available guards: `PKG_GPL`, `PKG_NONFREE`, `PKG_LINUX_ONLY`, `PKG_SKIP_ON_ARCH`, `PKG_REQUIRES_CMD`, `PKG_REQUIRES_MESON`.

## Enabled Libraries

A full `--enable-nonfree` build enables 64 features across these categories:

**Video codecs:** x264, x265, libvpx (VP8/VP9), aom (AV1), dav1d (AV1 decode), svtav1 (AV1 encode), rav1e (AV1 encode), xvidcore, kvazaar (HEVC), openh264, vid.stab, zimg

**Audio codecs:** opus, lame (MP3), vorbis, theora, fdk-aac, opencore-amr, soxr, speex, twolame (MP2), gsm, libilbc, vo-amrwbenc, libshine (MP3), lv2

**Subtitle/text:** libass, harfbuzz, fribidi, fontconfig, freetype

**Image formats:** libjxl (JPEG XL), libwebp, libpng, openjpeg (JPEG 2000)

**Media formats:** libbluray, librtmp, libxml2 (DASH), libsrt, librist

**Audio processing:** rubberband (time-stretch), libmysofa (HRTF), bs2b (crossfeed), chromaprint (fingerprinting)

**Filter plugins:** frei0r, ladspa

**HW acceleration:** vaapi, vulkan, glslang, AMF, OpenCL, NVENC/NVDEC/CUVID

**Miscellaneous:** libcaca (ASCII output), codec2, flite (TTS), libgme (game music), libopenmpt (tracker music), libsnappy, libzmq, vapoursynth, libzvbi

## License

MIT License. See [LICENSE](LICENSE) for details.

FFmpeg itself is licensed under LGPL 2.1+, with optional GPL and non-free components enabled via `--enable-gpl` and `--enable-nonfree` flags. See individual recipe files for dependency licenses.
