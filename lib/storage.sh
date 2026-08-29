#!/bin/sh
# shellcheck shell=sh
# Whether the filesystem a build is about to be written to can survive it.
#
# mediaforge derives both working directories from the INVOCATION directory --
# DISTDIR="$TOPDIR/packages", PREFIX="$TOPDIR/workspace" -- so where the build
# lands is wherever the operator happened to be standing. That is usually a
# checkout on disk, and occasionally /tmp, which on Linux is RAM.
#
# The difference matters more than the free-space number suggests. A build that
# exhausts a disk fails the build: recipes stop, the operator gets an error, the
# machine is fine. A build that exhausts a tmpfs exhausts MEMORY -- the OOM
# killer starts choosing processes, and the failure is not confined to
# mediaforge. Measured on the host this was written for: /tmp is 7.8GB of tmpfs
# and a full tree is 25GB of packages/ plus 9.1GB of workspace/, so the build
# cannot fit and the machine goes down before it finds out.
#
# Worse, it does not clean up after itself. A run killed by the OOM killer is
# SIGKILLed, which no shell can trap (see tests/signal-cleanup.sh and GH-64), so
# the tree it had written stays in RAM and the next run starts with less.
#
# Hence a REFUSAL for the RAM case rather than a warning, and a warning for the
# merely-tight case. The asymmetry is the point: one is recoverable and the
# other takes the machine with it.

# The free space a full build wants, in 1K blocks. Measured 2026-08-29 on a
# complete --enable-nonfree --enable-static tree: packages/ 25GB (tarballs plus
# extracted sources) and workspace/ 9.1GB (headers, static archives, binaries),
# so ~34GB before the FFmpeg build itself and its logs. 40GiB is that plus
# headroom, and it is deliberately a FLOOR TO WARN AT rather than a refusal: a
# smaller build -- free codecs only, or a --disable list -- legitimately fits in
# far less, and refusing one would be wrong.
MF_MIN_FREE_KB=41943040

# The filesystem type under $1, or empty when it cannot be determined.
#
# Two probes, both GNU: `df -T` and `stat -f -c %T`. Neither exists in that form
# on macOS, whose df has no -T and whose stat -f takes a format string with an
# entirely different meaning -- so on macOS this returns empty and the caller
# treats the type as unknown. That is the correct answer there rather than a
# gap: /tmp on macOS is disk-backed, so the RAM case this guards against does
# not arise, and the free-space floor below still applies.
mf_fs_type() { # dir
  _mf_fs_ty=$(df -PT -- "$1" 2>/dev/null | awk 'NR==2 {print $2}') || _mf_fs_ty=''
  if [ -z "$_mf_fs_ty" ]; then
    _mf_fs_ty=$(stat -f -c '%T' -- "$1" 2>/dev/null) || _mf_fs_ty=''
  fi
  printf '%s' "$_mf_fs_ty"
}

# Available 1K blocks under $1, or empty when df cannot say.
#
# `df -P` rather than plain df: -P is the POSIX output format, which guarantees
# the entry is on ONE line. Without it a long device name wraps and field 4 of
# "line 2" is the mount point rather than the available blocks -- a number that
# looks plausible and means nothing.
mf_free_kb() { # dir
  df -P -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# The guard itself. $2 is the operator's --allow-tmpfs answer, so the refusal
# has an override and the override is visible at the call site rather than read
# from a global here.
mf_storage_guard() { # dir  allow_ram(true|false)
  case "$(mf_fs_type "$1")" in
    tmpfs | ramfs | devtmpfs)
      if [ "$2" = true ]; then
        warn "building into RAM ($1) — a full tree is larger than most tmpfs mounts, and running one out of memory takes more than this build with it"
      else
        die "$1 is on a RAM-backed filesystem. A build that fills it exhausts memory rather than disk, and the OOM killer's SIGKILL leaves the tree behind because no shell can trap it. Build from a directory on disk, or pass --allow-tmpfs if you know this one is large enough."
      fi
      ;;
  esac

  # Unreadable df output is NOT a refusal. An unknown filesystem, a container
  # with a stubbed df, a platform whose df says something else -- none of those
  # is evidence of a problem, and a guard that stops the build whenever it
  # cannot measure is a guard that gets disabled.
  _mf_free=$(mf_free_kb "$1")
  case "$_mf_free" in
    '' | *[!0-9]*) return 0 ;;
  esac
  if [ "$_mf_free" -lt "$MF_MIN_FREE_KB" ]; then
    warn "$((_mf_free / 1048576))GB free under $1; a full tree measures about 34GB. A smaller selection fits, but a full build will not."
  fi
}
