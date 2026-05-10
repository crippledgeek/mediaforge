# mediaforge interactive menu

Run `./mediaforge.sh build --menu` to launch a four-screen wizard. mediaforge prefers `whiptail` when installed; otherwise it falls back to a numbered text prompt that works on any POSIX shell.

`--menu` and `--yes` are mutually exclusive. `--menu` also bypasses the `$PREFIX/.mediaforge-choices` stored choices — every menu invocation re-asks every question.

## Screen 1 — Licence tier

```
+--------- Licence tier ---------+
| ( ) free                       |
| ( ) gpl                        |
| (*) nonfree                    |
+--------------------------------+
```

- `free` enables only LGPL-compatible recipes.
- `gpl` adds x264/x265/xvidcore/vid_stab.
- `nonfree` further adds fdk_aac and srt-over-openssl.

## Screen 2 — Build options

```
+--------- Build options --------+
| [ ] static                     |
| [ ] small                      |
| [x] lv2                        |
| [ ] rebuild                    |
+--------------------------------+
```

- `static` — full static binary (Linux only).
- `small` — minimal feature set, drops doc.
- `lv2` — default-on; untick to skip the LV2 audio-plugin chain (faster build).
- `rebuild` — rebuild outdated dependencies.

## Screen 3 — Mutex group picks

One radiolist per group. The default is highlighted.

```
+--------- TLS backend ----------+
| (*) gnutls                     |
| ( ) openssl                    |
| ( ) mbedtls                    |
| ( ) libressl                   |
| ( ) none                       |
+--------------------------------+
```

Same pattern for AAC, H.264, H.265, AV1 encoder. The H.264 and H.265 screens appear only when `gpl` or `nonfree` was chosen on Screen 1.

## Cancel handling

Pressing **Esc** or **Cancel** at any screen aborts the build with `menu cancelled`. Pressing **OK** with no items ticked (Screen 2) is treated as "no overrides for this screen" — the build continues with defaults.

## POSIX fallback

When `whiptail` is absent, the same four screens are rendered as numbered lists. Type the number of the choice and press Enter; press Enter on an empty line to confirm a checklist with current ticks. Empty input on a radiolist accepts the default.

```
Pick a TLS backend
  1) gnutls — GnuTLS — free, default
  2) openssl — OpenSSL — Apache 2.0
  3) mbedtls — mbedTLS — small footprint
  4) libressl — LibreSSL libtls
  5) none — No TLS support
Enter choice [1-5, default 1]: 
```

## Smart prompts (without `--menu`)

Even without `--menu`, mediaforge will prompt once per unresolved mutex group when stdin is a TTY and `--yes` is not passed. This is the "user enabled `--enable-nonfree` without picking a TLS backend" case.

In non-interactive contexts (`--yes`, no TTY, or `$CI` set), the conservative defaults from §4 of the design spec apply silently.
