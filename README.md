# mediaforge

A POSIX shell build system that compiles FFmpeg from source with ~50 modular dependency recipes. Supports multiple FFmpeg versions via build profiles.

Rewrite of [markus-perl/ffmpeg-build-script](https://github.com/markus-perl/ffmpeg-build-script) from monolithic Bash to portable, maintainable `#!/bin/sh`.

## Features

- **Modular recipes** — each dependency is a self-contained shell file
- **Version profiles** — pin all dependency versions per FFmpeg release (8.0.1, 7.1, 7.0, 6.1)
- **License tiers** — free, GPL, and non-free codec selection
- **Cross-platform** — Linux and macOS (including Apple Silicon)
- **Full static binaries** — optional fully static build on Linux
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
| `meson` + `ninja` | dav1d (AV1 decoder), lv2 (audio plugin hosting) |
| `nvcc` (CUDA toolkit) | NVIDIA hardware acceleration (nv-codec headers) |

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
./mediaforge.sh -b

# Build with GPL codecs (x264, x265, xvidcore, vid.stab)
./mediaforge.sh -b --gpl

# Build with GPL + non-free codecs (adds openssl, fdk-aac)
./mediaforge.sh -b --nonfree
```

## Usage

```
Usage: mediaforge.sh [OPTIONS]

Options:
  -h, --help                     Display usage information
      --version                  Display version information
  -b, --build                    Start the build process
      --gpl                      Enable GPL-licensed codecs (x264, x265, etc.)
      --nonfree                  Enable GPL + non-free codecs (implies --gpl)
      --disable-lv2              Disable LV2 libraries
  -c, --cleanup                  Remove all working dirs
      --latest                   Rebuild outdated dependencies
      --small                    Prioritize small size; skip manpages
      --full-static              Full static binary (Linux only)
      --skip-install             Do not install binaries to system
      --auto-install             Install binaries without prompting
      --profile <name>           Use version profile (e.g., 7.1, 8.0.1)
      --list-profiles            List available version profiles
      --check-updates            Check for newer dependency versions on GitHub
```

## Version Profiles

Profiles pin all ~50 dependency versions to a known-good set for a specific FFmpeg release:

```sh
# List available profiles
./mediaforge.sh --list-profiles

# Build FFmpeg 7.1 with its matching dependency set
./mediaforge.sh -b --profile 7.1

# Switch profiles (use --latest to rebuild changed deps)
./mediaforge.sh -b --profile 6.1 --latest
```

| Profile | FFmpeg | Release |
|---------|--------|---------|
| `8.0.1` | 8.0.1  | 2025    |
| `7.1`   | 7.1    | Sep 2024 |
| `7.0`   | 7.0    | Apr 2024 |
| `6.1`   | 6.1    | Nov 2023 |

Without `--profile`, recipes use their built-in default versions (equivalent to the 8.0.1 profile).

## Update Checking

Check if newer versions of dependencies are available on GitHub:

```sh
./mediaforge.sh --check-updates
./mediaforge.sh --check-updates --profile 7.1

# Use a GitHub token for higher API rate limits
GITHUB_TOKEN=ghp_xxx ./mediaforge.sh --check-updates
```

Packages not hosted on GitHub show `N/A`.

## Project Structure

```
mediaforge.sh              Main driver — CLI parsing, recipe orchestration
lib/
  utils.sh                 Core utilities (logging, build gating, execute)
  platform.sh              OS/arch detection (Linux, macOS, Apple Silicon)
  framework.sh             Recipe lifecycle (run_recipe, reset, guards, phases)
  download.sh              Tarball download with cache and retry
  cleanup.sh               Signal trap handler
  install.sh               Post-build binary installation
  updates.sh               GitHub API update checker
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

1. `mediaforge.sh` sources all `lib/*.sh` and parses CLI flags
2. If `--profile` is set, the profile file is sourced (setting `PKG_VERSION_*` variables)
3. Iterates `recipes/_order.conf`, calling `run_recipe()` for each entry
4. Each recipe sets `PKG_*` variables and optionally overrides build phases
5. Recipes use `${PKG_VERSION_NAME:-default}` so profiles can override versions
6. After all recipes, accumulated flags are applied and FFmpeg is built
7. Binaries are optionally installed to the system

## Writing Recipes

Each recipe is a shell file that sets variables and optionally overrides phase functions:

```sh
PKG_NAME="mylib"
PKG_VERSION="${PKG_VERSION_MYLIB:-1.0.0}"
PKG_URL="https://example.com/mylib-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-mylib"

# Optional: override any build phase
pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}
```

Available guards: `PKG_GPL`, `PKG_NONFREE`, `PKG_LINUX_ONLY`, `PKG_SKIP_ON_ARCH`, `PKG_REQUIRES_CMD`, `PKG_REQUIRES_MESON`.

## License

See individual recipe files for dependency licenses. FFmpeg itself is licensed under LGPL 2.1+, with optional GPL and non-free components enabled via `--gpl` and `--nonfree` flags.
