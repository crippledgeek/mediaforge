#!/bin/sh
# Platform detection — single source of truth for OS/arch info

OS_TYPE=$(uname -s)
OS_ARCH=$(uname -m)

IS_DARWIN=false
IS_LINUX=false
IS_FREEBSD=false
IS_MACOS_SILICON=false

case "$OS_TYPE" in
  Darwin)
    IS_DARWIN=true
    if [ "$OS_ARCH" = "arm64" ]; then
      IS_MACOS_SILICON=true
    fi
    ;;
  Linux)   IS_LINUX=true ;;
  FreeBSD) IS_FREEBSD=true ;;
esac

# Multiarch triplet for pkg-config paths
MULTIARCH=""
if command_exists dpkg-architecture; then
  MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) || MULTIARCH=""
fi
if [ -z "$MULTIARCH" ] && command_exists gcc; then
  MULTIARCH=$(gcc -dumpmachine 2>/dev/null) || MULTIARCH=""
fi

# Parallel job count detection
# $NUMJOBS env var overrides automatic detection
detect_jobs() {
  if [ -n "$NUMJOBS" ]; then
    printf '%s' "$NUMJOBS"
  elif [ -f /proc/cpuinfo ]; then
    grep -c processor /proc/cpuinfo
  elif [ "$IS_DARWIN" = true ]; then
    sysctl -n machdep.cpu.thread_count
  elif command_exists nproc; then
    nproc
  else
    printf '4'
  fi
}

MJOBS=$(detect_jobs)
