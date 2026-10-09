#!/bin/sh
# test/mux-env-seams.t - the ENVIRONMENT surface, against the code that reads
# it. The companion to test/mux-config-sample.t, which does the same job for
# $MUX_DIR/config keys, and for the same reason: a hand-kept list of knobs is
# a second copy of a fact, and a second copy needs a check rather than
# somebody remembering. That list had gone TEN NAMES stale.
#
# A SEAM IS A NAME THE CODE READS FOR A VALUE IT DID NOT COMPUTE, which is the
# distinction that makes this checkable at all:
#
#   ${X:-default}        read with a fallback            SEAM
#   X=${X:-default}      self-defaulting assignment      SEAM
#   X=anything else      the code computed it            OUTPUT, not a seam
#
# WITHOUT THAT RULE THERE IS NO LIST. mux's MUX_* names are a mix of seams and
# internal channels (MUX_CTX_PARTITION and MUX_CTX_SRC are what
# mux_ctx_resolve ANSWERS, MUX_WIN_ID is what mux_window_open answers,
# MUX_EC_* are the exit codes, MUX_GLYPH_* are constants), and documenting an
# output as a knob invites somebody to set it and then wonder why mux ignored
# them. Nothing in the tree distinguished the two before this.
#
# AND ONE NAME MUST NEVER BE DOCUMENTED, which is the sharper half and the
# reason this is not merely tidiness. MUX_SEND_POLICY_FILE relocates the
# root-owned send policy, and lib/mux-send-policy_lib says at the site that it
# is "overridable ONLY for the test suite ... this must never be documented as
# a user seam or read from config", because a variable the governed agent can
# point at a file it owns defeats the whole mechanism. That was a comment and
# nothing else: a well-meant sweep documenting "all the environment
# variables" would have undone a security decision, silently, and read as an
# improvement. It is asserted ABSENT now, with its reason.
set -eu
_name=mux-env-seams
. "$(dirname "$0")/harness_lib"

MAN=$HERE/man/man1/mux.1
SAMPLE=$HERE/share/config.sample

# FORBIDDEN: must be read by the code and documented NOWHERE. One entry, and a
# second one should be argued for rather than appended.
_forbidden='MUX_SEND_POLICY_FILE'

# --- the classifier -------------------------------------------------------
# EVERY SHIPPED SHELL FILE, which includes the share/ hooks: three of the
# undocumented names this found are et-probe's and ssh-probe's own bounds, and
# a hook shipped BY mux has a surface as much as a verb does. Not tests: a
# test setting a variable says nothing about mux's surface.
#
# `MUX_RESOLVED_*` IS EXCLUDED AS A CLASS. It is mux's output TO an envhook
# (the resolved set, exported under a prefix so a possibly-dead candidate
# stays out of the hook's own environment), so it reads as a seam from inside
# the hook and is a channel from outside. Documenting it as a knob would
# invite somebody to set it.
_SHIPPED="$HERE/bin/mux $HERE/setup.sh"
# THE NOTIFIER'S TWO HOOK DIRECTORIES WERE MISSING, and that is the third
# time a rule written for "the hook directory" has gone stale here: this
# list named latch, envhooks.d and demo while its own comment above claims
# EVERY shipped shell file. `MUX_TOAST_DIM` was read by two shipped hooks
# and documented nowhere, and this audit exists for precisely that.
for _d in "$HERE"/lib/*_lib "$HERE"/libexec/* "$HERE"/share/latch/* \
          "$HERE"/share/envhooks.d/* "$HERE"/share/demo/* \
          "$HERE"/share/desktop-notifier/focus/* \
          "$HERE"/share/desktop-notifier/toast/*; do
  [ -f "$_d" ] || continue
  case $_d in *__pycache__*) continue ;; esac
  _SHIPPED="$_SHIPPED $_d"
done
_seams=$(
  # shellcheck disable=SC2013,SC2086   # a variable NAME cannot contain a
  # space, so splitting the scrape on words is exactly right; $_SHIPPED is a
  # deliberately split file list
  for _v in $(grep -rhoE 'MUX_[A-Z_]+' $_SHIPPED 2>/dev/null | sort -u); do
    # `(pat)`, because this `case` is inside a `$( )` and bash 3.2 finds the
    # end of a substitution by COUNTING PARENTHESES: an unparenthesised
    # pattern's closing `)` closes the substitution early and the `;;` is then
    # a syntax error. macOS /bin/sh IS bash 3.2, so this file did not parse
    # there at all and died with no verdict. test/lint.t catches the class.
    case $_v in (MUX_RESOLVED_*) continue ;; esac
    # read with a fallback at least once
    # shellcheck disable=SC2086
    grep -qE "\\\$\{$_v:-" $_SHIPPED 2>/dev/null || continue
    # ... and never assigned from anything but its own default
    # shellcheck disable=SC2086
    _asg=$(grep -hE "(^|[[:space:]])(export )?$_v=" $_SHIPPED 2>/dev/null \
           | grep -vcE "$_v=\\\$\{$_v:-" || true)
    [ "${_asg:-0}" -eq 0 ] || continue
    printf '%s\n' "$_v"
  done
)

# VACUITY FIRST, because a classifier that stops matching makes every
# assertion below pass about the empty set. mux has carried well over twenty
# seams since latch's five landed, so a count in single figures means the
# scrape broke rather than that the surface shrank.
_n=$(printf '%s\n' "$_seams" | grep -c . || true)
[ "${_n:-0}" -ge 20 ] || fail "the seam classifier found ${_n:-0} names, which
cannot be right: mux has carried more than twenty since the five latch seams
landed. The read-vs-assign scrape has stopped matching."

# --- every seam is documented, except the one that must not be ------------
# Either place counts: the man page's ENVIRONMENT section, or config.sample
# for a knob whose config twin is documented there (env-timeout is both).
# config.sample is itself held against the code by mux-config-sample.t, so
# depending on it here is not a third copy.
_undoc=
for _v in $_seams; do
  case " $_forbidden " in *" $_v "*) continue ;; esac
  # ANCHORED, because a substring match reads MUX_STRIP_WIDTH as documented
  # when the page says MUX_STRIP_WIDTH_XX. Proven by doing it.
  grep -qE "^\.B(R)? .*\b$_v\b" "$MAN" && continue
  grep -q "$_v" "$SAMPLE" 2>/dev/null && continue
  _undoc="$_undoc $_v"
done
[ -z "$_undoc" ] || fail "read by the code and documented nowhere:$_undoc
Add each to man/man1/mux.1 ENVIRONMENT, or to share/config.sample if it has a
config twin. A knob a user cannot discover is a knob that does not exist."

# --- and the forbidden one is absent from both ----------------------------
# ASSERTED IN BOTH FILES, because the harm does not depend on which one a
# reader found it in.
for _v in $_forbidden; do
  # shellcheck disable=SC2086
  grep -qE "\\\$\{$_v:-" $_SHIPPED 2>/dev/null \
    || fail "$_v is on the forbidden list but nothing reads it any more, so
this assertion is guarding a name that no longer exists. Drop it from the
list rather than leaving a rule about nothing."
  grep -qE "^\.B(R)? .*\b$_v\b" "$MAN" && fail "$_v is documented in the man
page and must not be: it relocates the root-owned send policy, so a
documented override is one the governed agent can point at a file it owns.
See lib/mux-send-policy_lib."
  grep -q "$_v" "$SAMPLE" 2>/dev/null && fail "$_v appears in
share/config.sample and must not: the whole point is that the override does
NOT live anywhere the agent can write. See lib/mux-send-policy_lib."
done

# --- nothing documented that the code does not read ----------------------
# The other direction, which fails differently: a name in ENVIRONMENT that
# mux never reads reads as a promise, so somebody sets it and the surface
# LOOKS configured. The inert-flag defect, met in the docs.
_dead=
# shellcheck disable=SC2013   # a variable name is one word; see above
for _v in $(grep -ohE '^\.B(R)? .*MUX_[A-Z_]+' "$MAN" \
            | grep -ohE 'MUX_[A-Z_]+' | sort -u); do
  # THE WHOLE PACKAGE for this direction, Python included: the notifier's
  # three switches are real knobs read by `os.environ.get`, so a scrape over
  # shell alone would report them as documented-but-dead.
  grep -rq "$_v" "$HERE"/bin "$HERE"/lib "$HERE"/libexec "$HERE"/share \
    "$HERE"/desktop-notifier "$HERE"/setup.sh 2>/dev/null \
    || _dead="$_dead $_v"
done
[ -z "$_dead" ] || fail "documented in ENVIRONMENT and read by nothing:$_dead
Either the name was renamed and the man page was not swept, or the knob is
gone. A documented knob nothing reads is worse than an undocumented one."

pass
