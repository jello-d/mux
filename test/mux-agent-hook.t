#!/bin/sh
# test/mux-agent-hook.t - the event -> state mapping, which is MUX'S.
#
# Until 0.51 an integrator's hooks.json spelled out mux's own vocabulary:
# which event means `working`, which means `idle`, which is only a `--beat`.
# The state machine was written down in somebody else's repo, so changing a
# rule meant a coordinated release, and when `--beat` stopped being able to
# resurrect a turn, that WAS a plugin edit. Now the wiring says only what
# happened and this table decides what it means.
#
# EVERY EVENT IS ASSERTED, not a sample. The table is the contract, and a
# mapping is exactly the kind of thing that looks obviously right while one
# row is wrong: a Notification landing on `working` instead of `blocked`
# would make a session that needs you look busy, which is the signal mux
# exists to carry, inverted.
set -eu
_name=mux-agent-hook
. "$(dirname "$0")/harness_lib"

XDG_RUNTIME_DIR=$T/run; TMUX=/tmp/fake/global,1,0; TMUX_PANE=%9
export XDG_RUNTIME_DIR TMUX TMUX_PANE
REC=$T/run/mux/agent-state/global/9

hook() {
  rm -f "$REC"; "$HERE/libexec/mux-agent-hook" "$@" </dev/null >/dev/null 2>&1
}
state() { cut -d' ' -f1 2>/dev/null <"$REC" || true; }

# --- the whole table ------------------------------------------------------
for _case in 'UserPromptSubmit working' 'PostToolUse working' \
       'SubagentStop working' 'Notification blocked' \
       'Stop idle' 'StopFailure idle' 'SessionStart idle'; do
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
  # one, and a second beat inside the window is MEANT to promote, so
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

# --- A SUBAGENT STOPPING IS NOT EVIDENCE OF A TURN -------------------------
# THE BUG, MEASURED 2026-10-13: a session's turn ended with Stop, then two
# "while you were away" recaps arrived 246s apart. The agent harness runs that
# recap as a SUBAGENT, so each fired SubagentStop, and as a plain beat the
# first left a corroboration mark and the second completed it: the session
# read WORKING for an hour with no turn running and nothing that would ever
# fire Stop to correct it. Reported as "after a compaction it still shows
# busy", which is how it looks from the strip.
agent_rec "$REC" idle %9 100 sess
rm -f "$REC.beat"
"$HERE/libexec/mux-agent-hook" SubagentStop >/dev/null 2>&1 || true
"$HERE/libexec/mux-agent-hook" SubagentStop >/dev/null 2>&1 || true
[ "$(state)" = idle ] \
  || fail "two SubagentStop events promoted an idle record to [$(state)].
That is the away-recap bug: a harness subagent is not evidence of a turn"
# AND IT LEAVES NO MARK, which is the half the state cannot show: a refresh
# that marked would let one recap plus one stray beat corroborate.
[ ! -f "$REC.beat" ] \
  || fail "a SubagentStop over idle left a corroboration mark"

# THE CONTROL, without which the case above passes on a rule that no longer
# promotes ANYTHING: two TOOL CALLS still corroborate an auto-mode turn,
# which is what the two-beat rule exists for and what the same day's log
# showed working correctly twice.
agent_rec "$REC" idle %9 100 sess
rm -f "$REC.beat"
"$HERE/libexec/mux-agent-hook" PostToolUse >/dev/null 2>&1 || true
"$HERE/libexec/mux-agent-hook" PostToolUse >/dev/null 2>&1 || true
[ "$(state)" = working ] \
  || fail "two PostToolUse beats left the record [$(state)]: the auto-mode
corroboration has stopped working, so a turn with no UserPromptSubmit
reads done for its whole run"

# AND A SUBAGENT STOPPING STILL DOES EVERYTHING ELSE A BEAT DOES: it resumes
# a blocked record (a permission was approved and the work continued) and it
# refreshes a working one. Narrowing it to idle is the whole fix.
agent_rec "$REC" blocked %9 100 sess
"$HERE/libexec/mux-agent-hook" SubagentStop >/dev/null 2>&1 || true
[ "$(state)" = working ] \
  || fail "SubagentStop no longer resumes a blocked record: [$(state)]"

# --- A COMPACTION MUST NOT FINISH A TURN ----------------------------------
# THE BUG, MEASURED: a context compaction fires SessionStart mid-turn, so the
# agent announces itself again while it is still working. Four of four compact
# boundaries in this box's logs produced `working -> idle` in the same second,
# one of them logged as `via SessionStart`. The strip then said done, the tray
# said done, a "Claude finished" banner fired, and `mux agent wait` would have
# told an orchestrator the turn was over. It was the HUMAN who noticed, twice
# in one day, which is the failure.
agent_rec "$REC" working %9 100 sess
"$HERE/libexec/mux-agent-hook" SessionStart >/dev/null 2>&1 || true
[ "$(state)" = working ] \
  || fail "SessionStart demoted a WORKING record to [$(state)]. That is the
compaction bug: a busy agent reads done until the human types, because the
0.49 straggler guard will not let one beat promote it back."

# ... AND IT STILL REPORTS ITSELF, or the refusal is invisible and the next
# person investigating a stuck record has nothing to go on.
agent_rec "$REC" working %9 100 sess
: >"$T/log"
MUX_LOG=$T/log "$HERE/libexec/mux-agent-hook" SessionStart \
  >/dev/null 2>&1 || true
grep -q 'kept working' "$T/log" 2>/dev/null \
  || fail "the refused SessionStart wrote nothing to the log:
[$(cat "$T/log" 2>/dev/null)]"

# BOTH DIRECTIONS, because a SessionStart that could never write `idle` would
# pass the assertion above and break the thing the row is FOR: a genuinely new
# agent has to appear on the strip. The record here is idle rather than absent,
# so this is an overwrite and not merely a create.
agent_rec "$REC" idle %9 100 sess
"$HERE/libexec/mux-agent-hook" SessionStart >/dev/null 2>&1 || true
[ "$(state)" = idle ] || fail "SessionStart over a non-working record wrote
[$(state)]: the qualifier has stopped it doing its job at all"

# AND `Stop` IS NOT QUALIFIED. Stop is an OBSERVATION that the turn ended, so
# it must be able to end one, if the guard were put on the whole `idle` state
# rather than on this one event, a finished turn would stay working forever,
# which these notes call the worse direction.
agent_rec "$REC" working %9 100 sess
"$HERE/libexec/mux-agent-hook" Stop >/dev/null 2>&1 || true
[ "$(state)" = idle ] \
  || fail "Stop could not end a turn: it left the record [$(state)]"

# --- A TURN THAT FAILS STILL ENDS ----------------------------------------
# THE BUG, MEASURED 2026-10-20: a prompt answered "Prompt is too long" ended
# the turn with StopFailure and no Stop, so the record stayed `working` while
# the agent sat at its prompt. Everything after that read it wrong.
agent_rec "$REC" working %9 100 sess
"$HERE/libexec/mux-agent-hook" StopFailure </dev/null >/dev/null 2>&1 || true
[ "$(state)" = idle ] \
  || fail "StopFailure left a working record [$(state)]: a turn that ended
in an API error reads busy until the human types"

# --- A Notification SAYS WHICH KIND IT IS --------------------------------
# The "waiting for your input" nudge is `idle_prompt`, a minute after a turn
# ended. Read as `blocked` over that stale `working`, the same session then
# showed as needing attention while it compacted.
note() {  # STATE TYPE: a Notification of that type over a STATE record
  agent_rec "$REC" "$1" %9 100 sess
  printf '{"hook_event_name":"Notification","notification_type":"%s"}' "$2" \
    | "$HERE/libexec/mux-agent-hook" Notification >/dev/null 2>&1 || true
}
note working idle_prompt
[ "$(state)" = idle ] || fail "the idle nudge over a working record wrote
[$(state)], want idle: the agent is at its input prompt, the turn is over"
note working permission_prompt
[ "$(state)" = blocked ] || fail "a permission prompt over a working record
wrote [$(state)], want blocked: that is the one that needs a human"
# AND THE NUDGE NEVER ANSWERS A PROMPT. A permission prompt left waiting is
# still waiting, whatever else the agent says about its input box.
note blocked idle_prompt
[ "$(state)" = blocked ] || fail "the idle nudge cleared a pending permission
prompt to [$(state)]: a human is still needed there"
# A SPACE after the colon is still JSON, and the match must not depend on
# one serialiser's formatting.
agent_rec "$REC" working %9 100 sess
printf '{"notification_type": "idle_prompt"}' \
  | "$HERE/libexec/mux-agent-hook" Notification >/dev/null 2>&1 || true
[ "$(state)" = idle ] \
  || fail "notification_type with a space after the colon was not read"

# --- the SOURCE travels, which is the point of the verb -------------------
# Stop and SessionStart both resolve to `idle`, so the record alone can never
# say which one wrote it, and a record that went idle MID-TURN is exactly
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
