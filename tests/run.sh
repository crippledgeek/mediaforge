#!/bin/sh
# Top-level test runner. Sequential — each script exits non-zero on failure.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

sh tests/shellcheck.sh
sh tests/version-ge.sh
sh tests/negative.sh
sh tests/dry-run-matrix.sh
sh tests/resolve-nonfree-aac.sh
sh tests/flac-removed.sh
sh tests/menu-stdin.sh
sh tests/fetch-fail-no-cache.sh
sh tests/download-retry-verify.sh
# Was never wired in, which is why dry-run-matrix.sh's contradicting lcevc row
# went unnoticed: the accurate test did not run and the inaccurate one did.
# Dry-run only, so it needs no built workspace — unlike the four named on the
# NOT-IN-SUITE line below, which assert against $PREFIX and stay manual.
#
# That line is read by tests/debug-levels.sh, which fails if any tests/*.sh is
# neither invoked here nor named there: a test file nothing runs cannot fail,
# and two had already reached that state (tests/ccache.sh, found by a security
# review, and tests/compiler-flags.sh, which was red at the time). Keeping the
# list machine-readable means the exemption and the prose cannot drift apart.
# NOT-IN-SUITE: lcevc-static-link.sh oapv-static-link.sh no-nested-archives.sh avs2-reorder-dts.sh
# Pins flag OWNERSHIP in lib/flags.sh -- the rule that a recipe may set CFLAGS
# but not without deriving from the composed one. Was never wired in either, and
# it FAILED silently against a branch that had already shipped: giflib's derived
# macro read as a clobber because the check could not see through the helper.
sh tests/compiler-flags.sh
sh tests/lcevc-default-off.sh
sh tests/libressl-pin-asm.sh
sh tests/libressl-trust-store.sh
sh tests/git-commit-pinning.sh
# Pins that no recipe fetches a FORGE-GENERATED archive (#69). Those tarballs
# are computed per request, so no digest can pin them (av1/gitiles, #19), and
# generating them is expensive enough that code.videolan.org fronts the
# endpoint with bot protection -- which serves a challenge page as HTTP 200 and
# killed two clean builds before the recipes moved off it.
sh tests/generated-archive-urls.sh
sh tests/install-containment.sh
sh tests/install-privileged-execs.sh
# Pins #15: install reconciles against the previous manifest instead of
# overwriting it, so a file an older build shipped and this one does not is
# removed rather than orphaned. Nothing else in the suite runs install TWICE,
# which is the only way the defect is reachable.
sh tests/install-manifest-reconcile.sh
# Pins #60: the transitive-util .pc files stay in the workspace and are excluded
# at install time instead of being deleted from it. Deleting them made the
# workspace single-use -- the recipes that own them are stamped, so the second
# build's FFmpeg configure resolved the names from the system and died on a
# link probe, blaming an unrelated library.
sh tests/pc-exclusions-durable.sh
sh tests/checksum-verification.sh
# Prose hygiene, not behaviour: a comment citing an in-tree file by LINE is
# correct only until the next edit above it, and nothing else in this suite
# reads a comment. It found fifteen such citations on the branch that added it,
# two of them already stale.
sh tests/comment-citations.sh
sh tests/recipe-identity.sh
# Pins that cmake is CONFIGURED in one place (mf_cmake) and the build type has
# one spelling. 21 hand-written `run cmake` lines agreed only by accident,
# and the build type is the knob a debug mode has to turn -- a recipe that keeps
# its own spelling stays Release while the rest move, and still links.
sh tests/cmake-single-entry.sh
# The meson sibling: 18 call sites across 13 recipes repeated the same four
# flags, six of them in lv2 alone. Grep-based, so it also covers the sites inside stamp_check
# guards that a behaviour diff cannot reach.
sh tests/meson-single-entry.sh
# The .pc sibling of the two above. Eight recipes hand-rolled the same two
# rewrites -- six byte-identical awk programs appending -lstdc++, two swapping
# -lgcc_s for -lgcc_eh -- and every one of them ran `awk ... > tmp && mv` with no
# check that the .pc was there, so a library whose upstream .pc name changed
# would link without the flag its recipe exists to add and nothing would say so.
sh tests/pc-rewrite-single-entry.sh
# The fourth sibling: every `rm -rf` a recipe performs. Twenty sites reset a
# build directory themselves -- eighteen writing both `rm -rf X` and `mkdir -p X`,
# two writing only the removal -- and six more dropped a path outright, and not
# one of the twenty-six looked at the status. A failed reset left the recipe
# configuring against the previous build's cache; a failed drop left the previous
# version's files in a prefix the staged merge only ever adds to. Both are a
# success now and a failure much later, with nothing pointing back at the recipe.
# Half grep (recipes/ contains no bare `rm -rf` at all, so a third policy cannot
# arrive unnoticed), half behavioural (each guard fires, and mf_remove_temp's
# deliberately does not).
sh tests/tree-removal-guards.sh
# Pins dav1d as library-only. FFmpeg links libdav1d.a and never runs the CLI,
# and dav1d's tools include the system xxhash.h, whose always_inline helpers
# make the recipe unbuildable below -O2 -- so the setting is what keeps dav1d
# debuggable, not merely smaller.
sh tests/dav1d-library-only.sh
# Pins --debug. The risk is not any single level but PARTIAL wiring: a level
# that reaches three of the four knobs (autotools CFLAGS, cmake build type,
# meson buildtype+b_ndebug, FFmpeg's own strip/debug flags) yields a tree that
# still compiles and links, with wrong stack traces in the recipes it missed.
sh tests/debug-levels.sh
# Pins .githooks/pre-push, which runs tests/shellcheck.sh -- and only that -- at
# push time. Asserts it forwards the gate's verdict both ways, demands a real
# linter rather than sh -n alone, and lets a branch deletion through. A hook that
# exited 0 regardless would leave the tree looking guarded when it is not, and
# nothing else here would notice.
sh tests/pre-push-hook.sh
# Pins that the agent-artifact ignore patterns actually BITE. .gitignore fails
# silently: a pattern that matches nothing is indistinguishable in `git status`
# from one that works, and the artifact just shows up untracked and committable.
# graphify-out/ was missing while every sibling was present, which is what this
# was written for. Asks git, not the file's text, so an inert pattern is a miss.
sh tests/gitignore-artifacts.sh
# Pins the sidecar provenance convention (#36): a comment claiming "<algo> from
# <URL>" must head a block that actually records that algo, and the extra
# upstream digests must be CHECKED rather than inert. Nothing else in the suite
# reads a provenance comment, so an overclaiming one is otherwise invisible.
sh tests/upstream-provenance.sh
# Pins the committed signing keys (#40): a `# with key <fpr>` line must have the
# matching keys/<fpr>.asc, a committed key must be cited by some block, and each
# INDEX row must state what the committed bytes themselves say. The pin alone
# records only WHICH key signed; expiry and revocation are self-signatures the
# holder can change afterwards, so without the material a recorded verdict can
# flip with no commit touching this tree.
sh tests/signing-keys.sh
# Pins the sidecar comment grammar (#45): overriding HASH_COMMENT_RE must change
# what hash_file_validate and hash_lookup do. Asserted by mutation rather than by
# grep, because the claim is that the parsers READ the shared definition -- a
# second copy spelled differently would satisfy a grep and still be a second
# copy. Nothing else in the suite would notice one.
sh tests/hash-comment-grammar.sh
# Pins the shared reporters and the evidence helper beside them (#46, #48): a
# defect in tests/lib-assert.sh
# does not fail a test — it changes what a passing test PRINTS, which is
# exactly what oracle-baseline below counts. Nothing else asserts on that
# output, and since #48 every test in this file routes through it, bar the two
# gates (shellcheck, oracle-baseline) that format their own output.
sh tests/ccache.sh
# Pins the refusal to build into RAM (#64). The working directories come from
# the invocation directory, so a build started under /tmp writes tens of
# gigabytes into tmpfs; filling that exhausts memory rather than disk, and the
# OOM killer's SIGKILL cannot be trapped, so the half-written tree stays.
sh tests/storage-guard.sh
# Pins which directory `clean` may remove (#71). The two are not
# interchangeable: workspace/ costs CPU to rebuild, packages/ costs an upstream
# still being willing to serve the same bytes -- and #70 is what the second one
# costs when it goes as a side effect of "remove all build artifacts". Nothing
# else in the suite runs the clean subcommand at all.
sh tests/clean-modes.sh
# Pins that mediaforge's own output cannot be rewritten by the values it prints,
# and that it refuses to run when `pwd` fails (#71 review). die() prints
# operator-supplied argv verbatim, and lib/download.sh already carried the same
# printable filter inline for text an origin chose -- so the rule now exists once
# as mf_printable and this asserts BOTH callers. The startup half matters because
# an empty $TOPDIR makes $DISTDIR "/packages", and the default clean now deletes
# under $DISTDIR rather than only the flagged form.
sh tests/output-and-startup-hygiene.sh
# Pins that a build stamp is EVIDENCE and not a claim (#59). A stamp used to be
# an empty file, so nothing noticed when one outlived the artifact it vouched
# for -- and the next build then skips a recipe it never built, failing at
# FFmpeg's link step instead. Covers both the recording half (staged installs,
# lib/stage.sh) and the reporting half (the reconcile subcommand).
sh tests/stamp-reconcile.sh
# The audit direction the file above cannot reach (#77): a file in the prefix
# that no stamp claims at all, rather than a stamp whose files went missing.
# Pins that it reports without gating -- the exit status is the decision, not a
# detail -- that the exclusion is the prefix's TOP-LEVEL dotfiles and not
# anything hidden at any depth, and that meson's bytecode is stopped at the
# generator instead of excluded from the audit.
sh tests/reconcile-unclaimed.sh
# The staging half of the same defect (#80): the manifest walk discarded find's
# status, so a subtree it could not descend was dropped from the stamp in
# silence -- and unlike the audit above, nothing ever re-derives a stamp. Pins
# the shared walk mechanism and the STAGING half of the policy split over it;
# the audit's half stays with the audit, in reconcile-unclaimed.sh above.
sh tests/stage-manifest-walk.sh
# Pins that a recipe installing by hand writes into the stage and not the live
# prefix (#68). DESTDIR redirects a build system's install target and nothing
# else, so a shell cp at "$PREFIX/..." staged nothing and went unrecorded. Both
# directions of the regression are invisible in a green build: a revert still
# installs the right files, and a stage path baked into a generated .pc still
# resolves until the stage is deleted. The last assertion is the one that
# outlives this branch -- it scans every recipe, because the eight the issue
# listed were the ones with EMPTY stamps and six more had a per-file gap inside
# a stamp that read `verified`.
sh tests/staged-shell-installs.sh
# Pins that FFmpeg's own install is staged and stamped (#77). cmd_build sources
# recipes/ffmpeg.sh directly rather than through run_recipe, where the staging
# window lives, so FFmpeg was the one package writing into the workspace with no
# manifest behind it -- 248 files, the largest single class of unclaimed path in
# a full prefix though not the last one. All the assertions are about ORDER,
# which is what a green build cannot check: the binary installs correctly
# whether or not the merge precedes the read-back.
sh tests/ffmpeg-stamped.sh
sh tests/assert-reporter.sh
# Pins that the suite's verdict is a function of the TREE and not of the
# developer's build state (#55). Eight files ran mediaforge with the repo as
# TOPDIR, so $PREFIX was the repo's own workspace/; the mixed-debug-level guard
# turned that from latent into a suite that fails outright on any machine
# carrying a --debug=full build. Runs each of them again against a poisoned
# workspace, which is the only way to observe the coupling from inside the
# suite -- every one of them passes on a clean machine either way.
sh tests/workspace-independence.sh
# Pins that an INTERRUPTED run leaves nothing behind (#64). Eight files cleaned
# up on EXIT alone, which under dash -- where /bin/sh is dash, not here -- means
# not at all when the run is signalled; what survives is a temporary tree in
# TMPDIR, and TMPDIR is tmpfs on many hosts, so the leak is RAM. Runs after
# workspace-independence because it SIGNALS that file as its subject.
sh tests/signal-cleanup.sh
# Runs the unmerged test files against the merge base and fails if any assertion
# passes there. Catches the oracle that drifted into matching an error message,
# and the fixture whose path collided with the value it was distinguishing —
# both real, both green under shellcheck and the suite.
sh tests/oracle-baseline.sh

printf 'All tests passed.\n'
