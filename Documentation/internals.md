How mediaforge works
====================

The layout of the tree and the order a build runs in. For writing a recipe,
see CONTRIBUTING.md.

## Project Structure

```
mediaforge.sh              Main driver — subcommand dispatch, recipe orchestration
lib/
  utils.sh                 Core utilities (logging, stamp gating, run)
  platform.sh              OS/arch detection (Linux, macOS, Apple Silicon)
  framework.sh             Recipe lifecycle (run_recipe, reset, guards, phases)
  download.sh              Tarball fetch, hash verification, cache and exponential backoff
  makesum.sh               makesum: fetch-and-record digests into .hash sidecars
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
  <name>.hash              Recorded sha256/size (+ optional sha512/sha1) sidecar,
                           one per recipe with a PKG_URL (see Checksum Verification)
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
