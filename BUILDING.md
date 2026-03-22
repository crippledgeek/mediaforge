# Building mediaforge

## Standard Build (Shared Linking)

Works out of the box on most Linux distros and macOS:

```sh
./mediaforge.sh build                        # free codecs
./mediaforge.sh build --enable-gpl           # + GPL codecs
./mediaforge.sh build --enable-nonfree       # + non-free codecs
```

## Full Static Build

Static builds (`--enable-static`) produce a single binary with no runtime dependencies. This requires **static versions** of all system libraries that the built codecs depend on.

```sh
./mediaforge.sh build --enable-nonfree --enable-static
```

### Static Build on Arch Linux

Arch Linux does not ship static libraries (`.a` files) in its official packages. You will see errors like:

```
/usr/bin/ld: cannot find -lexpat: No such file or directory
/usr/bin/ld: have you installed the static version of the expat library ?
```

#### Required Static Libraries

The following system libraries need static (`.a`) versions for a full static build:

| Library | Arch Package | Needed By |
|---------|-------------|-----------|
| `libexpat.a` | expat | fontconfig → libass |
| `libbz2.a` | bzip2 | freetype |
| `liblzma.a` | xz | libtiff → libjxl |
| `libunibreak.a` | libunibreak | libass |
| `libbsd.a` | libbsd | srt |
| `libmd.a` | libmd | libbsd |
| `libdeflate.a` | libdeflate | libtiff → libjxl |
| `libjbig.a` | jbigkit | libtiff → libjxl |
| `libjpeg.a` | libjpeg-turbo | libjxl |
| `libunwind.a` | libunwind | various |

#### Options to Get Static Libraries on Arch

**Option 1: Rebuild packages with staticlibs (recommended)**

```sh
# Example: rebuild expat with static lib
asp checkout expat
cd expat/trunk
# Edit PKGBUILD: add 'staticlibs' to options=() array
makepkg -si
```

**Option 2: Use AUR static packages**

Some AUR packages provide static versions:

```sh
yay -S expat-static bzip2-static
```

**Option 3: Build without static**

If you don't need a fully portable binary:

```sh
./mediaforge.sh build --enable-nonfree    # shared linking, works everywhere
```

### Static Build on Ubuntu/Debian

Debian-based distros ship static libraries in `-dev` packages:

```sh
sudo apt install \
  libexpat1-dev \
  libbz2-dev \
  liblzma-dev \
  libunibreak-dev \
  libbsd-dev \
  libmd-dev \
  libdeflate-dev \
  libjbig-dev \
  libjpeg-dev \
  libunwind-dev
```

Most `-dev` packages include both `.so` and `.a` files.

### Static Build on macOS

macOS does not support fully static binaries (`-static` flag). Use the standard build instead:

```sh
./mediaforge.sh build --enable-nonfree
```

## Build Profiles

Pin all dependency versions to a known-good set:

```sh
./mediaforge.sh build --profile=7.1
./mediaforge.sh build --profile=6.1 --rebuild-outdated
```

See `profiles/` directory for available versions.

## Build Artifacts

All build output is contained in two directories:

| Directory | Contents |
|-----------|----------|
| `packages/` | Downloaded tarballs, extracted sources |
| `workspace/` | Built libraries, headers, binaries, stamp files |

These are fully isolated — no system modifications until `install`.

### Stamp Files

Build progress is tracked via stamp files in `workspace/.stamps/`:

```
workspace/.stamps/x264-0.164
workspace/.stamps/x265-4.1
workspace/.stamps/opus-1.5.2
```

To force a rebuild of a specific package, remove its stamp file:

```sh
rm workspace/.stamps/x264-*
./mediaforge.sh build --enable-gpl
```

To rebuild everything:

```sh
./mediaforge.sh clean
./mediaforge.sh build --enable-nonfree
```

### Build Logs

Failed builds leave log files in `workspace/.logs/`:

```
workspace/.logs/libass-configure.log
workspace/.logs/x265-build.log
```

Successful builds clean up their logs automatically.

## Troubleshooting

### "gcc is unable to create an executable file"

Usually means a static library is missing. Check `packages/<pkg>/ffbuild/config.log` for the specific linker error. See the Static Build section above.

### "pkg-config: not found"

mediaforge builds its own pkg-config. If this recipe fails, check that `make` and `gcc` are installed.

### Recipe fails after an upgrade

Remove the stamp file for the failed package and rebuild:

```sh
rm workspace/.stamps/<package>-*
./mediaforge.sh build --enable-nonfree
```

### Clean rebuild

```sh
./mediaforge.sh clean
./mediaforge.sh build --enable-nonfree
```
