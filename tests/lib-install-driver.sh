# shellcheck shell=sh
# One definition of "run something with the install layer loaded".
#
# Every install-layer `sh -c` in tests/ opened a fresh shell and repeated the
# same three source lines, and most of them repeated the same environment prefix
# around `do_install` / `do_uninstall` verbatim. No census is written down here:
# the first draft of this paragraph counted the call sites and was wrong by one
# before it was committed -- lib/install.sh's own header declines to count its
# sourcers for exactly that reason.
#
# The lines do not rot quietly -- a wrong order fails loudly -- but the file's
# DEPENDENCIES are a real thing to keep in step: lib/install.sh calls
# resolve_openssldir from lib/resolve.sh, and two of these sites did not source
# it. Having one place say what the install layer needs is what makes that
# answerable.
#
# A separate `sh` process rather than a ( ) subshell, which is the reason every
# one of those call sites gave: do_install reads PREFIX/AUTOINSTALL from the
# environment, and shadowing the calling test's own PREFIX inside a subshell
# would both confuse the reader and leak install.sh's functions into the
# assertions that follow.
#
# Requires the sourcing test to have set $_root to the repo root.

# The load order mediaforge.sh uses at the top of the file: utils.sh, then
# resolve.sh, then lib/install.sh at each subcommand that needs it. Named
# rather than cited by line -- this comment's first draft said ":26" and was
# wrong by the time it was committed, because the commit that wrote it had
# inserted a source line above resolve.sh. tests/comment-citations.sh is the
# gate for that, and it now catches this spelling too.
#
# Double-quoted with escaped dollars rather than single-quoted. The dollars are
# equally literal to the inner shell either way, and this spelling keeps the
# linter's "expressions don't expand in single quotes" check quiet without a
# suppression -- which matters because a spliced `sh -c` script is a string
# argument like any other, so the exemption granted to a LITERAL `sh -c` script
# does not apply to it.
_MF_INSTALL_SOURCES="
  . \"\$SCRIPT_DIR/lib/utils.sh\"
  . \"\$SCRIPT_DIR/lib/resolve.sh\"
  . \"\$SCRIPT_DIR/lib/install.sh\"
"

# _install_sh <prefix> <entrypoint> [arg...]: run one install-layer entry point
# (do_install / do_uninstall) against <prefix>, with stderr merged so callers
# need no redirection of their own.
#
# The entry point is passed as ARGUMENTS rather than spliced as text, so no
# call site has to quote a shell fragment. The bespoke drivers -- the ones
# running a probe, a sudo shim or two commands in one process -- splice
# $_MF_INSTALL_SOURCES themselves instead; they share the dependency list,
# which is the part worth having once, and nothing else.
#
# MF_SCRIPT_DIR overrides the tree the install layer is loaded FROM, which is
# how tests/install-manifest-reconcile.sh drives a deliberately damaged copy of
# lib/remove-listed-files.sh.
_install_sh() {
  _isd_prefix=$1
  _isd_entry=$2
  shift 2
  PREFIX="$_isd_prefix" INSTALL_MANPAGES=0 AUTOINSTALL=yes \
  SCRIPT_DIR="${MF_SCRIPT_DIR:-$_root}" VERBOSE=0 \
    sh -c "$_MF_INSTALL_SOURCES\"\$@\"" _ "$_isd_entry" "$@" 2>&1
}
