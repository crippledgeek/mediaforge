Build requirements
==================

What mediaforge needs on the host, and what each optional tool buys.
See BUILDING.md for platform-specific notes.

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
