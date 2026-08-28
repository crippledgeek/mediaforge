# shellcheck shell=sh
# The `# with key <fingerprint>` pin grammar, defined ONCE.
#
# The comment MARKER that heads such a line is not here: it lives in
# lib/download.sh, which parses the same sidecars to read their digests, and this
# file sources it below. #45 moved it there. The split follows the consumers --
# a build asks where the records are, only the tests ask which keys the tree
# pins -- and putting the marker anywhere else left the production parser
# holding a hand-written copy of it.
#
# Two files ask different questions of this line -- tests/upstream-provenance.sh
# asks whether a stanza is well formed, tests/signing-keys.sh asks which
# fingerprints the tree pins -- but the grammar itself is one piece of knowledge,
# and it was implemented twice before this file existed. The two copies had
# already drifted on the day they were written: one folded case before matching
# and the other did not, so `# With key <fpr>` counted as a well-formed pin in
# the first file while being INVISIBLE to the second -- which meant the key it
# named was never required to be committed. That is the exact failure both files
# argue in their own comments that they close.
#
# So the recogniser lives here and both call sites use it. A change to the
# grammar reaches both by construction rather than by someone remembering.
#
# Recognition is two steps, and they are separate on purpose:
#
#   PROVENANCE_PIN_INTENT_RE -- "was this line MEANT as a pin", matched against
#     the comment body lowercased. Any hex-ish token qualifies, so a malformed
#     fingerprint is still recognised as an attempted pin and can be reported as
#     malformed. Prose ("with key rotation pending upstream") is not hex and so
#     is not a pin -- reading its third word as a fingerprint once failed the
#     whole gate on a comment. End-anchored: trailing text means the line says
#     something the grammar does not cover, so it is not a pin either.
#
#   PROVENANCE_FPR_RE -- "is it a USABLE pin", matched against the token as
#     written. Uppercase is required because that is what `gpg --fingerprint`
#     prints and what Arch's validpgpkeys requires, and 40 hex characters is the
#     full fingerprint rather than a truncated long-id.
#
# A line matching the first but not the second is a malformed pin: loud, and
# never counted as a usable one.
#
# HASH_COMMENT_RE, from lib/download.sh, strips the marker. It is shared for the
# same reason the two above are: "how much of the line is the marker" is part of
# the same grammar, and it was the half still written three times after the
# first convergence -- once here and once in each of lib/download.sh's two
# parsers.
# Its no-backslash constraint is documented at its definition and applies to
# every consumer, this file's `sed` included.
#
# Requires $ROOT to be set by the caller, for the source line below.

# shellcheck source=lib/download.sh
. "$ROOT/lib/download.sh"

PROVENANCE_PIN_INTENT_RE='^with[[:space:]]+key[[:space:]]+[0-9a-f]+[[:space:]]*$'
PROVENANCE_FPR_RE='^[0-9A-F]{40}$'

# provenance_pinned_fprs FILE...
# Emit each USABLE pinned fingerprint, sorted and deduplicated.
#
# The leading `#` is stripped before the fields are read rather than matched as
# a field, because `#with key X` and `# with key X` differ in field NUMBER and
# only the second would be seen -- an unrecognised pin here is invisible, which
# is the failure this file exists to prevent.
provenance_pinned_fprs() {
  sed -n "s/$HASH_COMMENT_RE//p" "$@" 2>/dev/null \
    | awk -v PIN="$PROVENANCE_PIN_INTENT_RE" -v FPR="$PROVENANCE_FPR_RE" '
        tolower($0) ~ PIN && $3 ~ FPR { print $3 }' \
    | sort -u
}
