Installing
==========

Where a build may be installed, and why the prefix matters more than it
looks. Read the doctrine before running install with sudo.

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
