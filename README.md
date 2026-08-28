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
  makesum            Fetch recipe sources and record their sha256/size sidecars
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
      --debug[=LEVEL]       Build with debug info (symbols|balanced|full)
                            Bare --debug means full. Forces LTO off.
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

Makesum options (used by the makesum subcommand):
  --profile=X.Y             Record digests against a specific version profile
  --update                  Overwrite an existing digest that no longer matches
  --build                   Run a real build with recording enabled, to reach
                            sub-build downloads (forwards remaining args to
                            build; no package filter)

Checksum verification (loud; never persisted to the stored choice matrix):
  --skip-checksum           Disable verification for EVERY recipe
  --skip-checksum=PKG       Disable verification for one recipe by name
                            (repeatable, comma-separated ok)

Install/uninstall options:
  --prefix=PATH             Install/uninstall location (default: interactive prompt)
  -y, --yes                 Non-interactive mode
```

### Debug builds

`--debug[=LEVEL]` builds every dependency and FFmpeg itself with debug
information. Three levels, with costs measured on this tree (lame, dav1d and
SVT-AV1 built at each):

| Level | Optimization | Assertions | Runtime cost | Archive size |
|---|---|---|---|---|
| `symbols` | `-O2 -g3` | off | none measurable | ~2x |
| `balanced` | `-Og -g3` | **on** | ~2x slower | ~2x |
| `full` (bare `--debug`) | `-O0 -g3` | **on** | 4-5x slower | ~3x |

Those figures come from building three packages — lame, dav1d and SVT-AV1 — at
each level on one machine and timing one fixture each. Treat them as the right
order of magnitude, not a promise. "Archive size" is the multiple applied to the
static `.a` files; the final `ffmpeg` binary grows more, since it links all of
them.

`symbols` is what distributions ship as debuginfo: identical performance, but a
crash gives a real backtrace with file and line. It is also the only level that
stays behaviourally identical to a release build — the other two enable
assertions, which can change behaviour.

All three set `-fno-omit-frame-pointer`, so backtraces are reliable even at
`symbols`, and `-g3` rather than `-g2`, which keeps macro definitions available
in the debugger.

The level reaches all four places a build's posture is decided: the composed
`CFLAGS` for autotools recipes, `CMAKE_BUILD_TYPE` for cmake ones, `buildtype`
plus `b_ndebug` for meson ones (meson does not tie `NDEBUG` to buildtype the way
cmake does), and FFmpeg's own `--enable-debug` / `--disable-stripping` — without
that last one the final binary is stripped whatever the ~110 libraries did.

`--debug` forces LTO off and says so: LTO discards the per-function debug info
that makes stepping work.

**A workspace remembers the level it was built at.** Build stamps record only a
recipe's name and version, so nothing about a build's *flags* is captured — a
release build followed by `--debug` would rebuild nothing but FFmpeg and produce
a debug binary linked against stripped, optimized archives, which compiles,
links and runs while every library's stack traces are wrong. mediaforge refuses
that instead: change the level on a populated workspace and it stops, telling
you to `./mediaforge.sh clean` (or remove `workspace/.stamps`) first.

**`--enable-small` overrides the level for FFmpeg itself.** FFmpeg's configure
picks its optimization in the order small → optimizations → none, so `libav*`
compiles at `-Os` while the ~110 dependencies still honour the debug level.
mediaforge warns when both are given.

### Examples

```sh
# Build with short flags
./mediaforge.sh build -Gs                # nonfree + static
./mediaforge.sh build -g -j 4            # GPL, 4 jobs
./mediaforge.sh build -n                  # dry run

# Debug builds
./mediaforge.sh build --debug             # -O0 -g3, assertions on (4-5x slower)
./mediaforge.sh build --debug=symbols     # -O2 -g3, no measurable slowdown
./mediaforge.sh build --debug=balanced    # -Og -g3, assertions on (~2x slower)

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

# Record/update checksum sidecars
./mediaforge.sh makesum                      # every recipe, plus the FFmpeg tarball
./mediaforge.sh makesum zlib openssl         # just these recipes
./mediaforge.sh makesum --profile=7.1        # against a specific profile's pinned versions
./mediaforge.sh makesum --update             # overwrite a digest that no longer matches

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

### Installing over an existing install

Install reconciles against the previous install's manifest before replacing
it. Every file the earlier build put in the prefix and this one does not ship
— a library that was renamed, merged into another archive, or dropped from the
build entirely — is removed, and the directories that empties go with
it. Without that step those files would stay on disk *and* disappear from the
record, which makes them permanently invisible to `uninstall`: the prefix
survives an uninstall that reports success, and a stale `.a` beside a matching
`.pc` can still be picked up by a downstream static link.

Two things it deliberately will not do. It never touches a file the manifest
did not list, so anything else living in a shared prefix is left alone. And an
install that copies nothing at all — an unbuilt or cleaned workspace — prunes
nothing and leaves the existing manifest in place, because with nothing
installed every previous entry would look like an orphan. It warns rather than
reporting a successful install of zero files — though the exit status stays 0,
since `build` runs install as its last step and an empty workspace is a state
to report, not a failure of the install. A script that needs to distinguish
them should check the prefix, not `$?`.

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

## Checksum Verification

Every recipe that fetches a tarball keeps a sidecar next to its own `.sh`
file — `recipes/video/x264.hash` beside `recipes/video/x264.sh` — recording
what was actually downloaded. `fetch()` verifies against it before
extraction, whether the file was just downloaded or was already sitting in
`packages/`; a cache hit is re-checked, not trusted forever, because a
tarball corrupted or swapped after landing there would otherwise never be
examined again.

**Sidecar grammar**: one record per line, `<keyword>  <value>  <filename>`
(whitespace-separated). `#` comments and blank lines are ignored.

```
# Locally calculated 2026-08-25
sha256  ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  lame-3.100.tar.gz
size    1524133  lame-3.100.tar.gz
```

`sha256` and `size` are both **mandatory** — a record missing either does
not count as verifiable, and the file is treated as unattested rather than
silently passed. Size is checked first (cheap, catches truncation before any
hashing); `sha512` and `sha1` are optional extra records, checked when
present. `md5`, `sha224` and `sha384` are rejected by the parser outright —
there is no code path that accepts them.

**Provenance comments.** The comment above each block records how the digest
was obtained, and the distinction is the point: a locally calculated digest
attests *these are the bytes we received*, while an upstream-published one
attests *these are the bytes upstream published*. Two forms, following
[Buildroot's `.hash` convention](https://buildroot.org/downloads/manual/manual.html):

```
# sha256 from https://downloads.xiph.org/releases/opus/SHA256SUMS.txt
sha256  b7637334527201fdfd6dd6a02e67aceffb0e5e60155bbd89175647a80301c92c  opus-1.6.tar.gz
size    36317446  opus-1.6.tar.gz
```

```
# sha512 from https://download.videolan.org/pub/videolan/libbluray/1.3.4/libbluray-1.3.4.tar.bz2.sha512
# sha256 locally calculated 2026-08-25 (upstream publishes sha512 only)
sha512  94dbf3b6...  libbluray-1.3.4.tar.bz2
sha256  478ffd68...  libbluray-1.3.4.tar.bz2
size    756323  libbluray-1.3.4.tar.bz2
```

A comment names the provenance of the **digest** records only — `size` is
derived here for every block, upstream ones included, and is never claimed by
a `from <URL>` comment.

**Which upstream digests get recorded.** The strongest one upstream publishes.
Several publishers ship a weaker digest beside it — most xiph directories
serve `SHA1SUMS` next to `SHA256SUMS` (`speex` is the exception, publishing
only `SHA256SUMS.txt`), and openssl uploads a `.sha1` next to its `.sha256` —
and those are deliberately *not* recorded: they come from the same publisher,
in the same directory, over the same transport, so once that publisher's
`sha256` is pinned their `sha1` is not an independent attestation, just a
second copy of the same trust root with a collision-broken algorithm attached.
This is a considered divergence from Buildroot, whose manual says it is "best
to add all those hashes".

Where upstream publishes **only** a weak digest the calculus inverts, because
then it is the only upstream attestation on offer: `libzmq` ships `SHA1SUMS`
and `MD5SUMS`, so its upstream `sha1` *is* recorded, alongside a locally
calculated `sha256`. `md5` is unrepresentable here by design. Every recorded
digest is checked — `verify_file` treats `sha512`/`sha1` as additional
requirements, never as alternatives to the mandatory `sha256`.

**Signature provenance.** A digest says the bytes match what was recorded; a
signature says *who published them*. Where upstream publishes a detached
OpenPGP signature and the signing key can be corroborated independently, the
block records both:

```
# sha256 from https://downloads.xiph.org/releases/vorbis/SHA256SUMS
# pgp signature verified https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz.asc
# with key B7B00AEE1F960EEA0FED66FB9259A8F2D2D44C84
sha256  0e982409…  libvorbis-1.3.7.tar.gz
size    1658963  libvorbis-1.3.7.tar.gz
```

The two lines are separate from the digest-origin comment on purpose. Buildroot
bundles them into one phrase (`# Locally calculated after checking pgp
signature`), which cannot express a digest that came from upstream's own
`SHA256SUMS` — the bundled wording would have to overwrite the origin in order
to state the signature. Split, a block says both, truthfully.

The fingerprint is the **primary** key's, even where a signing subkey made the
signature (`bzip2` and `libressl` are both signed by a subkey), because the
primary is what an independent packager pins and therefore what can be
corroborated.

**Corroboration is the whole point, and it bounds what this buys.** A signature
checked against a key fetched from the same host as the artifact proves nothing
— so every recorded key was cross-checked against Arch Linux's `validpgpkeys`,
an independent packaging organization that vetted the same key; `libssh` and
`libtiff` also match the fingerprint Buildroot records. Two of those
cross-checks are weaker than the rest and say so here rather than in a footnote:
Arch pins `gnutls`'s key (Daiki Ueno) in its **gettext** recipe, having
commented it out of `gnutls` in favour of a newer signer, and `pkg-config`'s pin
lives in a PKGBUILD Arch has frozen since migrating to `pkgconf` — every other
distro checked pins nothing there, so Arch is its sole corroborator.

**Nothing is recorded that cannot be defended.** Four recipes publish a
signature that verifies and are still deliberately absent:

| Recipe | Why not recorded |
|---|---|
| `libtool` | Arch pins no key, and the signing key changed between 2.4.6 and 2.4.7 |
| `speex` | verifies, but no independent source pins the key |
| `libressl` | signed 2026-05-26 by a key that expired 2026-03-03 |
| `nettle` | signed 2025-06-26 by a key that expired 2025-01-15 |

The last two are **withheld, not disqualified.** Key expiry is a self-signature
the holder can extend at any time, and extending it flips every past signature
from `EXPKEYSIG` to `GOODSIG` — nothing about the signature or the bytes
changes. `nettle` shares `gmp`'s key, so if Niels Möller extends
`343C2FF0…828C67298` then `nettle` becomes recordable on exactly the evidence
that is failing today. The dates above are what a future maintainer needs to
re-check; do not read their absence as a permanent verdict.

The last two are worth knowing about as a trap, not just an outcome: **`gpgv`'s
human-readable output prints "Good signature" for a signature made by an expired
key.** Only the status codes distinguish them — `gpg --status-fd` returns
`EXPKEYSIG` rather than `GOODSIG`. Six of the sixteen signatures checked here
return `EXPKEYSIG`; for four of them the signature predates the expiry and the
key has merely lapsed since — validity is evaluated at signing time, so a key
lapsing afterwards does not retroactively invalidate what it signed, the same
way an expired TLS certificate does not — but for `libressl` and `nettle` the
signature postdates it.

**Verify with status codes, not with the message a human reads.** This
generalizes past `gpg`: no verification tool's prose output is a reliable
verdict, because `GOODSIG`, `EXPKEYSIG`, `REVKEYSIG` and a name-mismatch
warning can all print text beginning "Good signature". Nothing in the tree
shells out to a verification tool today — `verify_file` computes digests
directly — so this is a rule for the next person who adds one: read the exit
status or `--status-fd`, never `grep` the stdout. Gentoo's `verify-sig` maintainer
is blunt about the ceiling here — *"The verify-sig mechanics do not provide any
way to verify the authenticity of installed OpenPGP keys"* — trust bottoms out
in a human vetting a fingerprint, and recording the fingerprint is what makes
that reviewable.

Verification happens at pin time, not build time, so **`gpg` is a maintainer
tool and never a build dependency**. Gentoo and Arch verify on the user's
machine because the pinning maintainer is not present there; here the digests
are already committed and diff-reviewed, so a build-time signature check would
re-verify what the pinned digest already guarantees.

These digests are transcribed by hand, once, and reviewed in the diff —
deliberately, not for want of tooling. Re-fetching the sums file on every
`makesum` run would re-derive the pin from the network each time and let
`--update` silently re-pin from it, which gives up exactly the property that
makes a committed digest worth having. `makesum` therefore always writes
`Locally calculated <date>`; an upstream attribution is something a human adds
after checking. `tests/upstream-provenance.sh` enforces that a comment claiming
`<algo> from <URL>` appears in a block that actually records that algorithm — an
overclaiming comment reads as an upstream attestation and would otherwise be
invisible.

Three recipes carry no `.hash` sidecar, by design: `librtmp`, `libplacebo`
and `av1` pin an exact 40-character git commit SHA instead
(`fetch_git()` in `lib/download.sh`) — a commit hash authenticates the
fetched tree directly, which a tarball digest can only approximate one step
removed. `vaapi` fetches nothing at all (`PKG_URL=""`) and has neither.

### Recording digests: `makesum`

```sh
./mediaforge.sh makesum                     # fetch + record every recipe, plus the FFmpeg tarball
./mediaforge.sh makesum zlib openssl        # just these recipes
./mediaforge.sh makesum --profile=7.1       # against a specific profile's pinned versions
./mediaforge.sh makesum --update            # overwrite a digest that no longer matches
./mediaforge.sh makesum --build --enable-nonfree   # real build with recording on, to reach
                                                     # sub-build downloads (lv2, opencl, libcdio, ...)
```

A cached tarball is re-downloaded rather than trusted, unless it already has
a recorded `sha256` that matches the bytes on disk — `makesum`'s own output
*becomes* the pin, so trusting an unattested cache entry would mint a pin
from bytes of unknown age. That policy holds for `--build` too, including the
sub-build downloads that have no record yet. Without `--update`, a digest
that no longer matches an existing record is reported and left untouched;
`--update` overwrites it, prints a reminder to confirm upstream genuinely
re-published before trusting the new value, and ends the run with a summary
block listing every digest it re-pinned. `--build` forwards every other
argument straight to the `build` subcommand's own parser and does not accept
a package filter — it exists to reach the `fetch()` calls nested inside a
recipe's `pkg_install()` (lv2's sub-tarballs, opencl's ICD-Loader, libcdio's
paranoia sub-package, vid_stab's cmake-quoting patch) that a fetch-only pass
over `_order.conf` never sources far enough to see. Plain `makesum` (no
`--build`) still reaches the FFmpeg tarball itself, even though
`recipes/ffmpeg.sh` isn't listed in `_order.conf` — `cmd_makesum` records it
as an explicit extra step whenever no package filter was given.

### Bypassing verification: `--skip-checksum`

```sh
./mediaforge.sh build --skip-checksum           # disable verification for every recipe
./mediaforge.sh build --skip-checksum=openssl   # disable it for one recipe only (repeatable, comma-separated ok)
```

Both forms print a loud warning banner at build start and again at build
end, and neither is ever written to the stored choice matrix
(`$PREFIX/.mediaforge-choices`) — a bypass is a one-run decision, not
something that should silently persist into the next build.
`--skip-checksum=PKG` is keyed by recipe filename (validated against the
recipe registry the same way `--enable=`/`--disable=` are), not by tarball
filename — that also covers a recipe's own sub-build downloads without the
caller needing to know their filenames (lv2's seven, for instance). `ffmpeg`
is accepted as well, for the FFmpeg tarball itself. An empty
`--skip-checksum=` is rejected rather than treated as "no recipes".

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
