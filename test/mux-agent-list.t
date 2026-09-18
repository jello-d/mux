#!/bin/sh
# test/mux-agent-list.t - `mux agent-list`, the per-session state feed.
#
# agent-summary collapses a namespace to one worst-state-and-count line. This
# keeps every session, which is what a tooltip, a right-click menu and a
# MULTI-HOST tray all need, and it is the verb a remote box answers with when
# the box you are sitting at runs `ssh <host> mux agent-list`.
#
# Three properties carry that remote use, and each is pinned below:
#
#   AGE, NOT EPOCH.  A reader on another machine must never subtract a remote
#                    clock's timestamp from its own now. The age is resolved
#                    here, against the clock that wrote the record.
#   EXIT 0 WHEN EMPTY.  "this host has no agents" and "I could not reach this
#                    host" must be different answers. No agents is an empty
#                    list and a zero exit; a non-zero exit can then only be the
#                    transport, and a presenter must render THAT as unknown.
#                    An unreachable host that reads as calm is how you stop
#                    checking a machine that needed you.
#   HEADLESS.        Derived from the state FILES, never from tmux, so it
#                    answers with no client, no server and no $TMUX.
set -eu
_name=mux-agent-list
. "$(dirname "$0")/lib.sh"

XDG_RUNTIME_DIR=$T/run
MUX_DIR=$T/conf
MUX_CACHE=$T/cache
export XDG_RUNTIME_DIR MUX_DIR MUX_CACHE
G=$XDG_RUNTIME_DIR/agent-state/global
mkdir -p "$G" "$MUX_DIR/partitions"

# No tmux on PATH AT ALL. The verb must never reach for it: its caller is a
# tray daemon or an ssh command on a box with no server attached.
mkdir -p "$T/bin"
for _c in sed awk grep cut tr head tail wc cat ls id date find sort \
          basename dirname mktemp rm mkdir cp mv readlink; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done

lst() {
	env -u TMUX -u MUX_SHARE PATH="$T/bin" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" MUX_DIR="$MUX_DIR" \
		MUX_CACHE="$MUX_CACHE" "$HERE/libexec/agent-state-list" "$@" 2>&1
}
# `_rc=0; _o=$(lst) || _rc=$?`: under set -eu a bare assignment aborts the
# moment the command exits non-zero, which is a case under test.
field() { printf '%s\n' "$1" | awk -v s="$2" '$3 == s { print $1, $2 }'; }

NOW=$(date +%s)

# --- one line per session, session LAST ------------------------------------
agent_rec "$G/1" working %1 "$((NOW - 60))" alpha
agent_rec "$G/2" idle    %2 "$((NOW - 3600))" bravo
_o=$(lst global)
[ "$(printf '%s\n' "$_o" | grep -c .)" -eq 2 ] \
	|| fail "want 2 lines, got: [$_o]"

# --- AGE, not the epoch ----------------------------------------------------
# The whole point of the remote case. An epoch here would make a reader on
# another box compute durations across two clocks.
_a=$(field "$_o" alpha)
case $_a in
"working 6"[0-9]) ;;
*) fail "alpha should read working with an age near 60s, got [$_a]" ;;
esac
# ... and the raw epoch must NOT appear anywhere in the output.
case $_o in
*"$((NOW - 60))"*) fail "the raw epoch leaked into the output: [$_o]" ;;
esac
_b=$(field "$_o" bravo)
case $_b in
"idle 36"[0-9][0-9]) ;;
*) fail "bravo should read idle with an age near 3600s, got [$_b]" ;;
esac

# --- a session name containing a SPACE survives ---------------------------
# Session LAST is what makes this work; `read -r st age sess` takes the rest.
agent_rec "$G/3" blocked %3 "$((NOW - 5))" 'my project'
_o=$(lst global)
printf '%s\n' "$_o" | grep -q ' my project$' \
	|| fail "a spaced session name did not survive: [$_o]"
# ... and it must not appear as its own first word.
printf '%s\n' "$_o" | awk '$3 == "my" && NF == 3' | grep -q . \
	&& fail "a phantom session 'my' was emitted"

# --- the WORST state wins for a session with several agent panes ----------
# Same rule as the strip and the summary, and it comes from the same function,
# so a session cannot look calm because one of its panes is idle.
agent_rec "$G/4" idle    %4 "$NOW" multi
agent_rec "$G/5" blocked %5 "$NOW" multi
_o=$(lst global)
[ "$(printf '%s\n' "$_o" | awk '$3 == "multi"' | grep -c .)" -eq 1 ] \
	|| fail "a multi-pane session was emitted more than once: [$_o]"
case $(field "$_o" multi) in
blocked*) ;;
*) fail "the worst pane state did not win: [$(field "$_o" multi)]" ;;
esac
rm -f "$G/4" \
      "$G/5"

# --- a record with no usable epoch is REPORTED, with an unknown age -------
# Dropping it would hide a live agent; a fabricated 0 would assert the state
# just began, which there is no evidence for.
printf 'working 0 %%9 - - oddball\n' >"$G/9"
_o=$(lst global)
case $(field "$_o" oddball) in
"working -") ;;
*) fail "no-epoch record: want [working -], got [$(field "$_o" oddball)]" ;;
esac
rm -f "$G/9"

# --- a FUTURE epoch clamps to 0, never negative --------------------------
agent_rec "$G/8" idle %8 "$((NOW + 9999))" future
_o=$(lst global)
[ "$(field "$_o" future)" = "idle 0" ] \
	|| fail "a future epoch should clamp to 0, got [$(field "$_o" future)]"
rm -f "$G/8"

# --- EMPTY but reachable is exit 0, and prints nothing -------------------
# The distinction the multi-host presenter is built on. If this ever exited
# non-zero for "no agents", every quiet host would render as unreachable.
_rc=0; _o=$(lst nosuchpartition) || _rc=$?
[ -z "$_o" ] || fail "an empty namespace printed something: [$_o]"
[ "$_rc" -eq 0 ] || fail "an empty namespace must exit 0, got $_rc"
# Same for a namespace whose directory exists but holds nothing.
mkdir -p "$XDG_RUNTIME_DIR/agent-state/bare"
_rc=0; _o=$(lst bare) || _rc=$?
[ -z "$_o" ] || fail "an empty dir printed something: [$_o]"
[ "$_rc" -eq 0 ] || fail "an empty dir must exit 0, got $_rc"

# --- READ-ONLY -----------------------------------------------------------
# It reports on the same directory agent-render PRUNES. A reporter that can
# damage what it reports is a mistake this codebase has already paid for.
_before=$(ls "$G" | LC_ALL=C sort | tr '\n' ' ')
_sum=$(cat "$G"/* | md5sum)
lst global >/dev/null 2>&1 || true
lst >/dev/null 2>&1 || true
_after=$(ls "$G" | LC_ALL=C sort | tr '\n' ' ')
[ "$_before" = "$_after" ] \
	|| fail "state files changed: [$_before] -> [$_after]"
[ "$_sum" = "$(cat "$G"/* | md5sum)" ] \
	|| fail "a state file's CONTENT was altered"

# --- headless: it must never call tmux -----------------------------------
# PATH above has no tmux at all, so any attempt would surface as an error in
# the output. Proven by a run that still produces the right answer.
case $(lst global) in
*"not found"*|*tmux*) fail "agent-list reached for tmux: [$(lst global)]" ;;
esac
printf '%s\n' "$(lst global)" | grep -q ' alpha$' \
	|| fail "headless run lost a session"

pass
