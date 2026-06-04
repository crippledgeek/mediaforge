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

# CMake policy floor for the bundled cmake (recipes/tools/cmake.sh, 4.x).
# CMake 4.0 hard-errors on cmake_minimum_required(VERSION < 3.5). A handful of
# the frozen codec sources we vendor still declare older minimums (libgme 2.6,
# vid_stab 2.8, frei0r/qrencode/libsnappy/uavs3d 3.1, chromaprint 3.3) and will
# never update their CMakeLists. CMAKE_POLICY_VERSION_MINIMUM is CMake's own,
# documented mechanism for this ("to help packagers and end users configure
# existing projects that have not been updated"); it only raises the policy
# floor for projects declaring a LOWER minimum — projects at >= 3.5 are
# untouched, and CMake < 3.25 ignores the variable.
#
# This is a deliberate, global setting because cmake is a build *tool* we own
# and drive for a curated, end-to-end-tested set of recipes — not the host's
# cmake. Distros (Fedora/Nixpkgs) patch per-package instead, because they build
# thousands of unaudited projects where a global floor could mask a real policy
# break; that risk does not apply at our scale. Override by pre-setting the var.
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

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
