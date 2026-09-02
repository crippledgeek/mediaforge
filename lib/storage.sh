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

# 1 GiB in the 1K blocks df -Pk reports, for turning that figure into something
# an operator reads. Named because the message is the guard's whole output and a
# bare 1048576 beside a second bare number is unreadable.
MF_KB_PER_GIB=1048576

# The filesystem type under $1, or empty when it cannot be determined.
#
# Two probes, both GNU: `df -T` (a column selector) and `stat -f -c %T`.
#
# macOS has neither, though not for the reason it first appears: BSD df DOES
# take -T, but it is a type FILTER taking a comma-separated list, and BSD stat
# -f takes a format string. So on macOS `df -PT -- "$1"` reads `--` as the type
# list -- which also means the end-of-options guard is not in force there, and a
# directory named like an option would be read as one. Harmless as called, since
# $TOPDIR is always absolute.
#
# Either way the probe yields nothing on macOS and the caller treats the type as
# unknown, which is the right answer there rather than a gap: /tmp on macOS is
# disk-backed, so the RAM case does not arise, and the free-space floor still
# applies.
mf_fs_type() { # dir
  _mf_fs_ty=$(df -PT -- "$1" 2>/dev/null | awk 'NR==2 {print $2}') || _mf_fs_ty=''
  if [ -z "$_mf_fs_ty" ]; then
    _mf_fs_ty=$(stat -f -c '%T' -- "$1" 2>/dev/null) || _mf_fs_ty=''
  fi
  printf '%s' "$_mf_fs_ty"
}

# Available 1K blocks under $1, or empty when df cannot say.
#
# `-P` is the POSIX output format, which guarantees the entry is on ONE line.
# Without it a long device name wraps and field 4 of "line 2" is the mount
# point rather than the available blocks -- a number that looks plausible and
# means nothing.
#
# `-k` is what makes "1K blocks" true rather than a hope. POSIX specifies
# 512-byte units for df; GNU coreutils defaults to 1024 but switches to 512
# under POSIXLY_CORRECT, and BSD (so macOS) is 512 natively. Measured on this
# host: `df -P /tmp` reports 8133104 and `POSIXLY_CORRECT=1 df -P /tmp` reports
# 16266208 for the same filesystem. Without -k the guard reads twice the free
# space it has and the warning never fires -- and it fails that way on macOS,
# the platform this file leans on the free-space check to cover.
mf_free_kb() { # dir
  df -Pk -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# The guard itself. $2 is the operator's --allow-tmpfs answer, so the refusal
# has an override and the override is visible at the call site rather than read
# from a global here.
mf_storage_guard() { # dir  allow_ram(true|false)
  case "$(mf_fs_type "$1")" in
    tmpfs | ramfs | devtmpfs)
      if [ "$2" = true ]; then
        warn "building into RAM ($1) -- a full tree is larger than most tmpfs mounts, and running one out of memory takes more than this build with it"
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
    # GiB throughout, and the floor named: truncating division put "39GB free"
    # beside "measures about 34GB" one block under the limit, which reads as a
    # warning contradicting itself.
    warn "$((_mf_free / MF_KB_PER_GIB))GiB free under $1; mediaforge warns below $((MF_MIN_FREE_KB / MF_KB_PER_GIB))GiB because a full tree measures about 34GiB. A smaller selection fits; a full build will not."
  fi
}
