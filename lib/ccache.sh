#!/bin/sh
# shellcheck shell=sh
# The compiler cache, in three states: auto (the default), true (--ccache) and
# false (--no-ccache). ONE of them answers for every build system in the tree --
# autotools, cmake, meson and bare make -- which is the whole point; see the
# meson paragraph below. (Cargo is the fifth and is excluded on purpose, for the
# reason at the bottom of this header.)
#
# Wired as a MASQUERADE DIRECTORY on PATH -- a directory of symlinks named after
# the compilers, each pointing at ccache -- rather than by prefixing CC/CXX.
# Three measured reasons, not a preference:
#
#   1. A recipe that sets its own CC still gets the cache. recipes/audio/gsm.sh
#      passes CC="gcc" on the make line, which beats any exported CC we compose;
#      a PATH entry it resolves that name through does not.
#   2. cmake mangles a CC that carries an argument. With CC="ccache gcc",
#      cmake 4.3.2 records CMAKE_C_COMPILER=/usr/bin/ccache and moves gcc into
#      CMAKE_C_COMPILER_ARG1 -- it works, but the cache file no longer names the
#      compiler, and anything reading it back gets ccache. With the masquerade
#      dir it records /usr/lib/ccache/bin/cc, which is a compiler.
#   3. One mechanism covers every build system that resolves compiler names
#      through PATH -- autotools, cmake, meson and the bare-make recipes;
#      wiring each build system's own launcher option would be four mechanisms
#      that agree only by inspection.
#
# The directory is built here rather than reusing a distro's (/usr/lib/ccache/bin
# on Arch, /usr/lib/ccache on Debian, a homebrew libexec on macOS) so there is no
# per-distro path table to keep current, and so the set of names is ours.
#
# Only names that ALREADY resolve get a symlink. Linking a clang that is not
# installed would make `command -v clang` succeed and hand a build system a
# compiler that cannot run -- the opposite of a cache's job, which is to change
# nothing but the time it takes.
#
# meson needs none of this and gets it anyway: meson finds ccache by itself and
# compiles with "/usr/bin/ccache cc" whether or not this ran (measured, meson
# 1.12.0). meson only does so when the compiler is NOT named in the environment
# or a machine file -- mesonbuild/compilers/detect.py calls detect_compiler_cache
# only on the branch where lookup_binary_entry found nothing -- and mediaforge
# exports no CC, so that is the branch C compilation takes everywhere. The one
# exception is C++ on Apple Silicon, where mediaforge.sh exports CXX=clang++
# (search for OS_MACOS_ARM): meson then takes the other branch and adds no cache
# of its own. Harmless, because that export happens AFTER mf_ccache_apply, so
# the name still resolves through the masquerade directory.
#
# So the flag makes the tree CONSISTENT rather than introducing the cache, and
# the nested case the combination produces -- ccache invoking a cc that is itself
# ccache -- is harmless: it compiles and returns 0, with no recursion error and
# no error counter moved (measured, ccache 4.13.6).
#
# That is also why "off" cannot be the absence of this file's work. The PATH
# directory is ours and meson does not need it; the only thing that reaches the
# ccache meson found by itself is CCACHE_DISABLE, which ccache reads to mean
# "just call the real compiler" -- verified against ccache 4.13.6, which
# compiled and created no cache directory at all under it. Before GH-61 the
# default was `false` and did nothing, so meson recipes compiled through a cache
# and the other four did not: a default that was neither cached nor uncached.
#
# Cargo is deliberately not wired. ccache caches C, C++, ObjC and CUDA; it runs
# rustc but does not cache it, so rav1e is unaffected either way.

# The one entry point. mediaforge.sh passes MF_CCACHE straight through, so the
# state-to-behaviour table lives here beside the mechanism it selects rather
# than as an `if` at the call site.
#
# `auto` degrades where `true` dies, and that difference is the reason there are
# three states rather than a flag defaulted to on: a host without ccache is
# ordinary and must still build, while an operator who typed --ccache asked for
# a faster build and would otherwise get a slower one with no explanation.
mf_ccache_apply() { # auto|true|false
  case "$1" in
    false) mf_ccache_off; return 0 ;;
    auto)
      # An operator who exported CCACHE_DISABLE has configured ccache the way
      # ccache documents, and `auto` -- which nobody typed -- has no standing to
      # overrule that. Presence is the test, not the value: ccache 4.13.6 reads
      # any set CCACHE_DISABLE as true, empty included, and rejects "0" outright
      # ("did you mean to set CCACHE_NODISABLE=true?"). CCACHE_NODISABLE can
      # still flip it back to enabled, in which case this defers to an
      # environment that wanted the cache after all -- meson caches, we do not
      # wire the rest, and the tree is split the way GH-61 describes. Nobody has
      # hit that combination; it is named rather than handled.
      if [ -n "${CCACHE_DISABLE+set}" ]; then
        log "ccache left to the environment (CCACHE_DISABLE is set)"
        return 0
      fi
      command_exists ccache || { mf_ccache_off; return 0; }
      ;;
    true)
      # Only the explicit flag clears it. An inherited CCACHE_DISABLE would
      # otherwise leave every compile running through ccache and caching
      # nothing -- the silent no-op that the die in mf_ccache_setup refuses to
      # allow from the other direction.
      unset CCACHE_DISABLE
      ;;
    *) die "internal: unknown ccache state '$1'" ;;
  esac
  mf_ccache_setup
}

# No cache anywhere, including the one meson finds without being asked. Set even
# when no ccache is installed: the state is then true by accident rather than by
# instruction, and a masquerade directory left on PATH by an outer environment
# would make the difference visible.
mf_ccache_off() {
  CCACHE_DISABLE=1
  export CCACHE_DISABLE
}

mf_ccache_setup() {
  command_exists ccache ||
    die "--ccache requested but ccache is not installed (pacman -S ccache / brew install ccache)"
  _mf_cc_bin=$(command -v ccache)
  _mf_cc_dir="${PREFIX:?}/.ccache-bin"
  rm -rf "$_mf_cc_dir"
  mkdir -p "$_mf_cc_dir" || die "Failed to create $_mf_cc_dir"
  _mf_cc_names=""
  for _mf_cc_name in cc gcc c++ g++ clang clang++; do
    command_exists "$_mf_cc_name" || continue
    ln -sf "$_mf_cc_bin" "$_mf_cc_dir/$_mf_cc_name" ||
      die "Failed to link $_mf_cc_name into $_mf_cc_dir"
    _mf_cc_names="$_mf_cc_names $_mf_cc_name"
  done
  [ -n "$_mf_cc_names" ] ||
    die "ccache is enabled but no C/C++ compiler was found on PATH"
  PATH="$_mf_cc_dir:$PATH"
  export PATH
  log "ccache enabled ($_mf_cc_bin) for:$_mf_cc_names"
}
