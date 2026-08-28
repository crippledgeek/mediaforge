#!/bin/sh
# shellcheck shell=sh
# Opt-in compiler cache. Off by default; --ccache turns it on.
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
#   3. One mechanism covers all five build systems. autotools, cmake, meson and
#      the bare-make recipes all resolve compiler names through PATH; wiring
#      each build system's own launcher option would be four mechanisms that
#      agree only by inspection.
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
# 1.12.0). So the flag makes the tree CONSISTENT rather than introducing the
# cache -- and the nested case the combination produces, ccache invoking a cc
# that is itself ccache, is harmless: it compiles and returns 0, with no
# recursion error and no error counter moved (measured, ccache 4.13.6).
#
# Cargo is deliberately not wired. ccache caches C, C++, ObjC and CUDA; it runs
# rustc but does not cache it, so rav1e is unaffected either way.
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
    die "--ccache requested but no C/C++ compiler was found on PATH"
  PATH="$_mf_cc_dir:$PATH"
  export PATH
  log "ccache enabled ($_mf_cc_bin) for:$_mf_cc_names"
}
