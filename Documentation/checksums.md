Checksum verification
=====================

Every fetched file is verified against a recorded digest. This is how the
sidecars are written, read, and — rarely — bypassed.

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
