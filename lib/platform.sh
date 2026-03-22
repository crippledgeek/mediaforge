#!/bin/sh
# shellcheck disable=SC2034
# Platform detection — single source of truth for OS/arch info

OS_TYPE=$(uname -s)
OS_ARCH=$(uname -m)

# shellcheck disable=SC2034
OS_MACOS=false
OS_LINUX=false
OS_FREEBSD=false
OS_MACOS_ARM=false

case "$OS_TYPE" in
  Darwin)
    OS_MACOS=true
    if [ "$OS_ARCH" = "arm64" ]; then
      OS_MACOS_ARM=true
    fi
    ;;
  Linux)   OS_LINUX=true ;;
  FreeBSD) OS_FREEBSD=true ;;
esac

# Multiarch triplet for pkg-config paths
MULTIARCH_TRIPLET=""
if command_exists dpkg-architecture; then
  MULTIARCH_TRIPLET=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) || MULTIARCH_TRIPLET=""
fi
if [ -z "$MULTIARCH_TRIPLET" ] && command_exists gcc; then
  MULTIARCH_TRIPLET=$(gcc -dumpmachine 2>/dev/null) || MULTIARCH_TRIPLET=""
fi

# Parallel job count detection
# $NUMJOBS env var overrides automatic detection
detect_jobs() {
  if [ -n "$NUMJOBS" ]; then
    printf '%s' "$NUMJOBS"
  elif [ -f /proc/cpuinfo ]; then
    grep -c processor /proc/cpuinfo
  elif [ "$OS_MACOS" = true ]; then
    sysctl -n machdep.cpu.thread_count
  elif command_exists nproc; then
    nproc
  else
    printf '4'
  fi
}

# shellcheck disable=SC2034
MJOBS=$(detect_jobs)
