#!/bin/sh
# The three removal policies, and the reason recipes never write `rm -rf`.
#
# Its own file rather than a corner of lib/framework.sh because the policy is
# what several things need in isolation: recipes call all three, and
# tests/staged-shell-installs.sh drives two recipes' install phases with stubs
# for the rest of the framework and needs the REAL removal here -- a stubbed one
# would be a second implementation of the policy under test, free to drift from
# it silently, which is the defect class GH-84 and GH-86 closed.
#
# Sourced by mediaforge.sh before lib/framework.sh. Requires die() and warn()
# from lib/utils.sh.

# Reset a build directory: remove whatever is there, then recreate it empty.
# Recipes call this instead of writing the removal and the creation out
# themselves, because not one of the twenty sites that did looked at either
# status -- eighteen of them wrote both statements, two wrote only the removal
# and left the build system to create the directory (GH-84).
#
# Nothing in mediaforge sets `set -e`, so `rm -rf build && mkdir -p build`
# failing is silent twice over: the `&&` short-circuits, so the directory is
# never recreated, and the non-zero status is discarded by the caller. The
# recipe then CONFIGURES AGAINST THE PREVIOUS BUILD'S TREE -- a CMake or meson
# cache holding paths, feature results and dependency locations from a source
# tree that no longer exists. The build succeeds; what breaks is FFmpeg's link
# step, nowhere near the recipe that caused it. That displaced shape -- a status
# dropped where nothing looks at it, surfacing far from its cause -- is the one
# GH-80 closed in the manifest walk.
#
# `rm -rf` failing is not hypothetical: a root-owned leftover from a `sudo`
# misfire is enough, and so is EBUSY on a path something still holds open.
#
# BOTH statuses are checked, because they fail for different reasons and a
# reader needs to know which happened: the removal fails on what is already
# there, the creation on the parent it has to write into. A single message
# covering both would name neither.
#
# Variadic, because recipes/video/x265.sh resets three sibling directories
# (8bit 10bit 12bit) as one step -- and it did so with `2>/dev/null` on the rm,
# which is the strongest form of the same defect: the error text discarded as
# well as the status.
#
# The removal half lives in mf_remove_tree below, which recipes also call on its
# own -- see there for the empty-argument policy and for the second removal
# shape in the tree.
#
# Deliberately NOT routed through `run`, which is the other way to reach a die.
# `run` returns 0 without acting under DRY_RUN, so a dry run would stop clearing
# build directories it clears today -- a behaviour change riding inside a fix,
# which is what nobody reviews for. It also logs to $PREFIX/.logs, and a
# directory reset has no output worth a log file.
mf_reset_dir() {
  [ "$#" -ge 1 ] || die "mf_reset_dir: called with no directory to reset"
  for _rd_dir in "$@"; do
    mf_remove_tree "$_rd_dir"
    mkdir -p -- "$_rd_dir" || die "Failed to create build directory: $_rd_dir"
  done
}

# The removal itself, and the POLICY that it must succeed. `rm -rf` on a path
# that is already absent succeeds, so this only fires on a removal that was
# genuinely refused -- a root-owned leftover from a `sudo` misfire, EBUSY on
# something still open, an unwritable parent.
#
# Recipes call it directly for the OTHER removal in the tree: dropping files a
# PREVIOUS version installed, at recipes/hwaccel/amf.sh, recipes/tools/meson.sh
# and recipes/video/xev{e,d}.sh (GH-86). Those aim at the live $PREFIX and have
# to, because the staged install merges with a tar pipe and the merge only ever
# ADDS -- the removal is the entire mechanism by which a shed header or a
# dropped Python module leaves the prefix. A silent failure there leaves the old
# version's files in a prefix that claims to hold the new one, and being claimed
# by no stamp they are invisible to the manifest too.
#
# An EMPTY argument is refused rather than acted on, and so is a call with no
# arguments at all. `mf_remove_tree "$_src/build"` with $_src unset expands to
# `/build`, which this cannot see -- but the empty case it can, and the rest of
# lib/ already holds that line: lib/download.sh and lib/cleanup.sh spell it
# `${x:?}` at their own `rm -rf` sites. Silently doing nothing is the worst
# answer available to a function whose whole contract is that the path is gone.
mf_remove_tree() {
  [ "$#" -ge 1 ] || die "mf_remove_tree: called with no path to remove"
  for _rt_path in "$@"; do
    [ -n "$_rt_path" ] || die "mf_remove_tree: empty path argument"
    rm -rf -- "$_rt_path" || die "Failed to remove: $_rt_path"
  done
}

# The other removal policy, named so the difference is in the code rather than
# in a reviewer's head: a `mktemp -d` scratch directory, where a failed removal
# leaks a temp tree and costs nothing else. Dying there would abort a build over
# a leak, so this reports and continues -- but it REPORTS, which the three bare
# `rm -rf`s it replaces (recipes/hwaccel/nv-codec.sh twice, recipes/other/lcevc.sh)
# did not.
#
# Having both policies as named functions is what lets tests/tree-removal-guards.sh
# assert that NO recipe removes a tree any other way. An allowlist of "these
# particular bare removals are fine" would have to be maintained by whoever adds
# the next one, which is precisely who will not know.
mf_remove_temp() {
  for _rtmp_path in "$@"; do
    [ -n "$_rtmp_path" ] || continue
    rm -rf -- "$_rtmp_path" || warn "Failed to remove temporary directory (leaked): $_rtmp_path"
  done
}
