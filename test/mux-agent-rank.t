#!/bin/sh
# test/mux-agent-rank.t - libexec/mux-agent-state_lib, the SINGLE SOURCE of the
# state ranking and the state glyphs.
#
# WHY IT GETS ITS OWN FILE. Seven programs source this lib (the session
# picker, `mux ls`, the status strip, agent-summary, agent-list, next-blocked
# and the doctor), and every one of them asks it the same question: which of
# these agents is the worst. So a silent change to the ranking does not break
# one consumer, it makes all seven AGREE ON THE WRONG ANSWER, which is the
# shape of bug nobody notices: the bar, the tray and the picker all say the
# same calm thing about a session that is waiting on you.
#
# Coverage said this file ran. Mutation said otherwise: with the ranking table
# guarded for the first time on 2026-09-26, two mutations SURVIVED the whole
# suite: `working` demoted below `idle`, and an unknown word promoted above
# everything. Both are tested below, and both are the reason for this file.
#
# Sourced directly, like test/mux-sessions.t does: the lib is functions and
# constants only, so the ranking can be asked about without a tmux, a server or
# a namespace.
set -eu
_name=mux-agent-rank
. "$(dirname "$0")/harness_lib"
. "$HERE/libexec/mux-agent-state_lib"

# --- the order itself, asserted as an ORDER and not as numbers -------------
# The values are an implementation detail; what every consumer depends on is
# that these four compare in this direction. Asserting `blocked = 3` would pin
# the wrong thing and fail on a harmless renumbering.
_b=$(mux_agent_rank blocked)
_w=$(mux_agent_rank working)
_i=$(mux_agent_rank idle)
_u=$(mux_agent_rank frobnicating)

[ "$_b" -gt "$_w" ] || fail "blocked ($_b) must outrank working ($_w)"
[ "$_w" -gt "$_i" ] || fail "working ($_w) must outrank idle ($_i)"
[ "$_i" -gt "$_u" ] || fail "idle ($_i) must outrank an UNKNOWN word ($_u)"

# The unknown case is the one a future mux reaches. A newer version on the far
# side of an ssh may emit a word this one has never heard of; if that outranked
# the known states, ONE such pane would decide the whole namespace's headline
# and the strip would report a word it cannot even draw a glyph for.
[ "$_u" -lt "$_b" ] || fail "an unknown word outranks blocked; a newer mux on
the other end of a transport would hijack the summary for every session"

# --- and the same order THROUGH mux_agent_state, pane by pane --------------
# Separate from the table above, because these are two different failures: the
# table can be right while the loop that consults it takes the first record, or
# the last, or the wrong field. Each pairing is asserted in BOTH glob orders,
# since the loop walks the directory and a comparison bug shows up in only one
# of them: `-ge` instead of `-gt` keeps the LAST equal record and looks
# correct until two panes tie.
D=$T/state
mkdir -p "$D"

worst() {   # <state for pane 1> <state for pane 2> -> the winning state
  rm -f "$D"/*
  agent_rec "$D/1" "$1" %1 100 sess
  agent_rec "$D/2" "$2" %2 200 sess
  # Word splitting is the POINT: the function returns "STATE EPOCH" as one
  # string and the two fields are what is being asserted.
  # shellcheck disable=SC2046
  set -- $(mux_agent_state "$D" sess)
  printf '%s' "${1:-}"
}

for _pair in 'blocked idle' 'blocked working' 'working idle' \
       'blocked frobnicating' 'idle frobnicating'; do
  # Deliberate: the loop carries two words per entry.
  # shellcheck disable=SC2086
  set -- $_pair
  _hi=$1 _lo=$2
  [ "$(worst "$_hi" "$_lo")" = "$_hi" ] \
    || fail "$_hi should beat $_lo (worse state second in the dir)"
  [ "$(worst "$_lo" "$_hi")" = "$_hi" ] \
    || fail "$_hi should beat $_lo (worse state first in the dir)"
done

# --- the EPOCH travels with the winning state ------------------------------
# The doctor reads it to decide whether a `working` record has outlived its
# turn, so a winner carrying the loser's timestamp would make a fresh record
# look hours old, or an old one look fresh. Asserted apart from the state,
# because the state can be right while the epoch comes from the other pane.
rm -f "$D"/*
agent_rec "$D/1" idle    %1 111 sess
agent_rec "$D/2" blocked %2 222 sess
# shellcheck disable=SC2046   # splitting "STATE EPOCH" is the assertion
set -- $(mux_agent_state "$D" sess)
[ "${1:-}" = blocked ] || fail "wrong winner: [${1:-}]"
[ "${2:-}" = 222 ] || fail "the winner carried the LOSER's epoch: [${2:-}]"

# --- a session with no tracked agent is not an error -----------------------
# The picker draws every session, most of which have no agent at all, so this
# is the common path rather than an edge case.
rm -f "$D"/*
agent_rec "$D/1" blocked %1 100 other
case "$(mux_agent_state "$D" sess)" in
' ') ;;
*) fail "an untracked session should read as a lone space, got
[$(mux_agent_state "$D" sess)]" ;;
esac

# --- glyphs: one per state, and all DIFFERENT ------------------------------
# The glyph is the only thing most users ever see of this lib. Two states
# sharing one is not a crash, it is a bar that silently stops distinguishing
# them, which is precisely what the bar exists to do.
_g=
for _s in blocked working idle '' frobnicating; do
  _this=$(mux_agent_glyph "$_s")
  [ -n "$_this" ] || fail "state [$_s] has no glyph"
  case "$MUX_AGENT_NL$_g$MUX_AGENT_NL" in
  *"$MUX_AGENT_NL$_this$MUX_AGENT_NL"*)
    fail "state [$_s] reuses the glyph [$_this]" ;;
  esac
  _g="$_g$MUX_AGENT_NL$_this"
done

# --- the session enumerator: distinct, and whole names ---------------------
rm -f "$D"/*
agent_rec "$D/1" blocked %1 100 'my project'
agent_rec "$D/2" idle    %2 200 'my project'
agent_rec "$D/3" idle    %3 300 zulu
_n=$(mux_agent_sessions "$D" | grep -c .)
[ "$_n" = 2 ] || fail "expected 2 distinct sessions, got $_n"
mux_agent_sessions "$D" | grep -qx 'my project' \
  || fail "a session name with a space did not survive enumeration"

# --- mux_agent_dir DERIVES, AND TOUCHES NOTHING ---------------------------
# THE REGRESSION GUARD FOR A PRODUCT BUG THIS SHIPPED, 2026-10-01. For one
# afternoon this function adopted the pre-namespacing state directory, and
# ELEVEN OF ITS TWELVE CALLERS ARE READ-ONLY: the status strip (per client,
# per status-interval), agent-summary, agent-list, next-blocked, the doctor,
# `mux ls`, the picker, and `mux check`, which this package requires never to
# be able to damage what it inspects. The copy it took then went stale while
# the still-deployed old writer carried on, and became authoritative at the
# next install: a session stuck reading `working`, which is the inversion
# these notes call worse than a stale idle.
#
# ASSERTED ON THE FILESYSTEM, NOT ON THE RETURNED PATH, because the path was
# always right. What was wrong was the side effect, and only an absence can
# see it. The adoption lives in setup.sh now, where the install is atomic with
# the writer switching over.
_rtp=$T/dirprobe
XDG_RUNTIME_DIR=$_rtp mux_agent_dir global >/dev/null
[ ! -e "$_rtp" ] || fail "mux_agent_dir CREATED [$_rtp]. It is called on
eleven read-only paths including 'mux check' and the status strip, so it must
derive a path and touch nothing. See setup.sh:_adopt_runtime_state."

# AND IT MUST NOT ADOPT, which is the specific shape that bit: an old-path
# directory sitting there is not an invitation to copy it.
mkdir -p "$_rtp/agent-state/global"
agent_rec "$_rtp/agent-state/global/1" working %1 100 stale
XDG_RUNTIME_DIR=$_rtp mux_agent_dir global >/dev/null
[ ! -e "$_rtp/mux" ] || fail "mux_agent_dir adopted the old state path. A
reader that migrates takes a SNAPSHOT, and a beat refreshes mtime without
advancing the epoch, so afterwards nothing can tell the copy from the live
record."

pass
