#!/bin/sh
# test/mux-agent-hook.t - the event -> state mapping, which is MUX'S.
#
# Until 0.51 an integrator's hooks.json spelled out mux's own vocabulary:
# which event means `working`, which means `idle`, which is only a `--beat`.
# The state machine was written down in somebody else's repo, so changing a
# rule meant a coordinated release -- and when `--beat` stopped being able to
# resurrect a turn, that WAS a plugin edit. Now the wiring says only what
# happened and this table decides what it means.
#
# EVERY EVENT IS ASSERTED, not a sample. The table is the contract, and a
# mapping is exactly the kind of thing that looks obviously right while one
# row is wrong -- a Notification landing on `working` instead of `blocked`
# would make a session that needs you look busy, which is the signal mux
# exists to carry, inverted.
set -eu
_name=mux-agent-hook
. "$(dirname "$0")/harness_lib"

XDG_RUNTIME_DIR=$T/run; TMUX=/tmp/fake/global,1,0; TMUX_PANE=%9
export XDG_RUNTIME_DIR TMUX TMUX_PANE
REC=$T/run/agent-state/global/9

hook() { rm -f "$REC"; "$HERE/libexec/mux-agent-hook" "$@" >/dev/null 2>&1; }
state() { cut -d' ' -f1 2>/dev/null <"$REC" || true; }

# --- the whole table ------------------------------------------------------
for _case in 'UserPromptSubmit working' 'PostToolUse working' \
             'SubagentStop working' 'Notification blocked' \
             'Stop idle' 'SessionStart idle'; do
	# shellcheck disable=SC2086   # two words per entry, split on purpose
	set -- $_case
	hook "$1" || fail "$1 exited non-zero"
	[ "$(state)" = "$2" ] || fail "$1 mapped to [$(state)], want [$2]"
done

# --- the BEATS are beats, and the turn start is not -----------------------
# The distinction the whole state machine rests on: a beat may refresh an
# existing `working` but must never create one out of `idle`, because `idle`
# means the turn ended. If PostToolUse stopped being a beat, a straggler
# would resurrect a finished turn and the session would show a brain glyph
# forever while sitting at a prompt.
for _beat in PostToolUse SubagentStop; do
	agent_rec "$REC" idle %9 100 sess
	# CLEAR THE CORROBORATION MARK between cases. A beat over idle leaves
	# one, and a second beat inside the window is MEANT to promote -- so
	# without this the loop tests the second event as the second beat and
	# reports the 0.49 rule working as if it were a mapping bug.
	rm -f "$REC.beat"
	"$HERE/libexec/mux-agent-hook" "$_beat" >/dev/null 2>&1 || true
	[ "$(state)" = idle ] \
		|| fail "$_beat is not being passed as a --beat: it promoted
an idle record on the first event, which is the straggler bug"
done
agent_rec "$REC" idle %9 100 sess
"$HERE/libexec/mux-agent-hook" UserPromptSubmit >/dev/null 2>&1 || true
[ "$(state)" = working ] \
	|| fail "UserPromptSubmit is being passed as a --beat: a turn START
must be able to leave idle, or nothing ever can"

# --- the SOURCE travels, which is the point of the verb -------------------
# Stop and SessionStart both resolve to `idle`, so the record alone can never
# say which one wrote it -- and a record that went idle MID-TURN is exactly
# that question. The breadcrumb is the only thing that answers it.
rm -f "$REC"
MUX_LOG=$T/log "$HERE/libexec/mux-agent-hook" Stop \
	>/dev/null 2>&1 || true
grep -q "via Stop" "$T/log" 2>/dev/null \
	|| fail "the hook name did not reach the log:
[$(cat "$T/log" 2>/dev/null)]"
rm -f "$REC"; : >"$T/log"
MUX_LOG=$T/log "$HERE/libexec/mux-agent-hook" SessionStart \
	>/dev/null 2>&1 || true
grep -q "via SessionStart" "$T/log" 2>/dev/null \
	|| fail "SessionStart and Stop are indistinguishable in the log, which
is the ambiguity this verb exists to remove"

# --- an unknown event is LOUD --------------------------------------------
# A named event mux does not know is an integrator claiming a contract that
# does not exist. Silence there would look exactly like a working hook.
_rc=0
"$HERE/libexec/mux-agent-hook" Frobnicate >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown event must exit 2, got $_rc"
_rc=0
"$HERE/libexec/mux-agent-hook" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "no event at all must exit 2, got $_rc"

pass
