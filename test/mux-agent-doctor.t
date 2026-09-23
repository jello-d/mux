#!/bin/sh
# test/mux-agent-doctor.t - does the recorded agent state match reality?
#
# The status strip reports state from per-pane files written by an agent's
# lifecycle hooks. When a hook does not fire the file keeps saying whatever it
# last said, and the bar reports a finished session that is busy -- observed
# live, twice, on two different machines. Nothing on the bar can contradict it,
# because the bar IS the file. So this verb asks the other side: is an agent
# process under that pane actually burning CPU?
#
# TWO things are pinned here, and the second matters as much as the first.
#
# 1. The BANDS. Measured across six live agents: a genuinely idle one sits at
#    0.1% of a core, agents mid-turn ran 3.7% to 9.8%. A naive "any CPU at all"
#    test called the idle ones working, so there are three bands and the middle
#    one is reported without being counted. MUX_DOCTOR_PROC relocates /proc so
#    a fabricated agent's CPU can be moved on cue.
#
# 2. That it is READ-ONLY. The renderer prunes state files it believes are
#    orphaned, which made it destructive when it could not see the server: one
#    diagnostic run of `mux agent-render` over ssh deleted four of five live
#    state files. This verb exists because reaching for a renderer to INSPECT
#    state was the mistake, so "it changes nothing" is a property worth a test
#    rather than a promise in a comment.
set -eu
_name=mux-agent-doctor
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/run/agent-state/global" "$T/proc" "$T/share/agents"
: >"$T/share/agents/claude.agent"

# A fabricated process table and pane list. pane %1 -> pid 100 -> claude 101.
# Both stubs read a FILE, so one case can change the world (add a pane, add a
# process) without every other case inheriting it.
PSTAB=$T/pstab; PANES=$T/panes; export PSTAB PANES
printf '  100     1 ksh\n  101   100 claude\n  200     1 ksh\n' >"$PSTAB"
# pane id, pane pid, then the SESSION -- session last, as everywhere else, so a
# name with a space survives.
printf '%%1 100 alpha\n%%2 200 beta\n' >"$PANES"
cat >"$T/bin/ps" <<'EOF'
#!/bin/sh
cat "$PSTAB"
EOF
PANE_TXT=$T/panetxt; export PANE_TXT
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-panes*)   cat "$PANES" ;;
*capture-pane*) [ -f "$PANE_TXT" ] && cat "$PANE_TXT" ;;
esac
exit 0
EOF
chmod +x "$T/bin/ps" "$T/bin/tmux"

# /proc/<pid>/stat: fields 14 and 15 are utime and stime. Only their sum is
# read, so the rest is padding.
setcpu() {   # <pid> <jiffies>
	mkdir -p "$T/proc/$1"
	_pad=$(awk 'BEGIN{for(i=1;i<=13;i++) printf "0 "}')
	printf '%s%s 0\n' "$_pad" "$2" >"$T/proc/$1/stat"
}

doc() {
	env -u TMUX -u MUX_SHARE PATH="$T/bin:$PATH" \
		XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" \
		MUX_SHARE="$T/share" MUX_DOCTOR_PROC="$T/proc" \
		MUX_DOCTOR_WINDOW="${WIN:-1}" \
		"$HERE/libexec/mux-agent-doctor" "$@" global 2>&1
}
# `_rc=0; _o=$(doc) || _rc=$?` throughout: under set -eu a bare `_o=$(doc)`
# aborts the moment doc exits non-zero, which is exactly the case under test.
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in: $1" ;; esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in: $1" ;; esac; }

# burn PID JIFFIES: move that process's CPU mid-window, which is the only way
# to exercise the bands against real elapsed time.
burn() { ( sleep 0.3; setcpu "$1" "$2" ) & }

# --- a busy agent whose file says idle is the reported bug ----------------
agent_rec "$T/run/agent-state/global/1" idle %1 1 alpha
setcpu 101 0
burn 101 40          # 40 jiffies in a 1s window = 40% of a core
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "DRIFT" "a busy agent recorded idle was not flagged"
has "$_o" "alpha" "the drifting session was not named"
[ "$_rc" -ne 0 ] || fail "drift must exit non-zero, got $_rc"

# --- an IDLE agent's background timers are not work -----------------------
# The naive "any CPU" test failed here: a genuinely idle agent still wakes for
# timers and spends a jiffy or two, which read as working and cried wolf.
setcpu 101 0
burn 101 1           # 1 jiffy in a 1s window = 1%
_rc=0; _o=$(doc) || _rc=$?
no_has "$_o" "DRIFT" "an idle agent's timer tick was called working"
[ "$_rc" -eq 0 ] || fail "no drift must exit 0, got $_rc"

# --- the middle band is reported, not counted ----------------------------
# Between clearly-idle and clearly-working is a band CPU alone cannot settle.
# Calling it DRIFT would cry wolf; hiding it would lose the signal.
setcpu 101 0
burn 101 3           # 3% -- above suspect, at the working threshold
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "suspect" "the middle band was not surfaced"
no_has "$_o" "DRIFT" "the middle band was counted as drift"
[ "$_rc" -eq 0 ] || fail "a suspect reading must not fail the run"

# --- recorded working with no agent at all -------------------------------
agent_rec "$T/run/agent-state/global/2" working %2 1 beta
rm -f "$T/run/agent-state/global/1"
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "gone" "a working record with no agent process was not surfaced"

# --- READ-ONLY: it must not add, remove or alter a single state file -----
# The property the renderer did not have.
agent_rec "$T/run/agent-state/global/1" idle %1 1 alpha
agent_rec "$T/run/agent-state/global/2" working %2 1 beta
setcpu 101 0
burn 101 40                                  # drift, the noisiest path
_before=$(ls "$T/run/agent-state/global" | LC_ALL=C sort | tr '\n' ' ')
_sum=$(cat "$T/run/agent-state/global"/* | md5sum)
doc >/dev/null 2>&1 || true
_after=$(ls "$T/run/agent-state/global" | LC_ALL=C sort | tr '\n' ' ')
[ "$_before" = "$_after" ] \
	|| fail "state files changed: [$_before] -> [$_after]"
[ "$_sum" = "$(cat "$T/run/agent-state/global"/* | md5sum)" ] \
	|| fail "a state file's CONTENT was altered"

# --- `working` with no CPU: stale record vs genuinely mid-turn -----------
# The one case CPU cannot settle, and the bug it hid. An agent waiting on the
# model or on a slow build is genuinely mid-turn AND idle on the CPU, so this
# was always reported as "quiet" rather than risk crying wolf. But a record left
# saying `working` after the turn ENDED looks identical from CPU alone.
#
# It is not hypothetical: seen twice in one day on two machines. A session that
# looks BUSY is one you deliberately leave alone, so the wait is unbounded --
# worse than the reverse direction, where a finished-looking session at least
# invites a glance.
#
# The tiebreaker is the AGENT's own UI, and the pattern comes from the agent
# DEFINITION so mux never learns what any particular agent's footer says.
printf 'busy    esc to interrupt\n' >"$T/share/agents/claude.agent"
agent_rec "$T/run/agent-state/global/1" working %1 1 alpha
rm -f "$T/run/agent-state/global/2"
setcpu 101 0
burn 101 0                                   # no CPU at all

# Marker PRESENT -> a turn is running. Must stay "quiet", never stale.
printf 'some output\n  auto mode on . esc to interrupt . for agents\n' \
	>"$PANE_TXT"
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "quiet" "a genuinely mid-turn agent was not reported quiet"
no_has "$_o" "STALE" "a mid-turn agent was wrongly called stale"
[ "$_rc" -eq 0 ] || fail "a mid-turn agent must not fail the run"

# Marker ABSENT -> the turn is over and the record outlived it.
printf 'some output\n  auto mode on . for agents\n' >"$PANE_TXT"
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "STALE" "a stale 'working' record was not surfaced"
has "$_o" "alpha" "the stale session was not named"
[ "$_rc" -ne 0 ] || fail "a stale record must exit non-zero, got $_rc"
# The REMEDY must match the cause. This direction reused the drift summary at
# first, which was wrong in both halves: it said a hook failed to fire when one
# fired that should not have, and it promised self-healing on the next tool call
# when nothing fires at all until a new turn starts.
has "$_o" "after the turn ENDED" "the stale summary did not name its cause"
has "$_o" "--beat" "the stale summary did not name the fix"
no_has "$_o" "self-heals on the agent's next tool call" \
	"the stale summary promised a recovery that cannot happen"

# An agent that declares NO marker leaves the verdict exactly where it was.
# Guessing one would make the doctor confidently wrong about a working agent.
: >"$T/share/agents/claude.agent"
_rc=0; _o=$(doc) || _rc=$?
no_has "$_o" "STALE" "a stale verdict was reached with no declared marker"
has "$_o" "quiet" "with no marker it should fall back to quiet"
[ "$_rc" -eq 0 ] || fail "no marker must not fail the run"
printf 'busy    esc to interrupt\n' >"$T/share/agents/claude.agent"

# A pane it cannot capture is not evidence either.
rm -f "$PANE_TXT"
_rc=0; _o=$(doc) || _rc=$?
no_has "$_o" "STALE" "an uncapturable pane produced a stale verdict"
[ "$_rc" -eq 0 ] || fail "a failed capture must not fail the run"
printf 'some output\n  auto mode on . esc to interrupt . for agents\n' \
	>"$PANE_TXT"
: >"$T/share/agents/claude.agent"

# --- --repair: the ONE finding that cannot heal itself -------------------
# Found live on manifold: session `fenix-binary` sat on a `working` record for
# days. The cause was upstream (an agent resolves its hooks ONCE at session
# start, so a session running since before the plugin gained --beat keeps
# promoting after the turn ends), but the point here is the RECOVERY. The other
# two findings recover on their own; this one cannot, because the turn is over
# and nothing further fires until a human starts a new one. Detecting a thing
# that only a restart can fix is a diagnosis without a cure.
#
# THE SCOPE IS THE INTERESTING PART, so each refusal below is pinned as tightly
# as the repair itself. A --repair that also "fixed" DRIFT would write `working`
# on a session that just finished, which is the worse direction; one that fixed
# an ORPHAN would have to invent a state from a CPU sample.
printf 'busy    esc to interrupt\n' >"$T/share/agents/claude.agent"
printf 'nothing that matches the marker\n' >"$PANE_TXT"
rm -f "$T/run/agent-state/global"/*
# A session name WITH A SPACE and a notification id, because the rewrite has to
# put six fields back in the order it found them. Hand-parsing a record is the
# trap this codebase has already paid for twice.
SFILE=$T/run/agent-state/global/1
agent_rec "$SFILE" working %1 1234 'my project' 777
setcpu 101 0
burn 101 0

# Without the flag it stays read-only ON THIS PATH TOO. The read-only case above
# covers drift; this is the path that gained the ability to write, so the
# default has to be re-proved here rather than inherited.
_sum=$(md5sum <"$SFILE")
_rc=0; _o=$(doc) || _rc=$?
# The BYTES are checked before the verdict string, deliberately. A repair that
# ran unconditionally would also change the verdict from STALE to REPAIRED, so
# asserting the verdict first reports "no stale record" -- which reads as a
# broken fixture and sends you to the wrong end of the file.
[ "$_sum" = "$(md5sum <"$SFILE")" ] \
	|| fail "a plain run rewrote a stale record. Read-only is the DEFAULT:
looking must never write, which is the whole reason --repair is opt-in."
has "$_o" "STALE" "the setup did not produce a stale record"
has "$_o" "mux agent-doctor --repair" "the stale summary did not offer the cure"

# With the flag: the state word changes and NOTHING else does.
setcpu 101 0
burn 101 0
_rc=0; _o=$(doc --repair) || _rc=$?
has "$_o" "REPAIRED" "--repair did not report repairing a stale record"
# Field by field FIRST, so the failure names which one moved. The epoch is kept
# on purpose: the turn ended at an unknown point AFTER working began, so
# stamping now would assert the one thing known to be false. The notif id is
# kept so the next real transition closes the banner the ordinary way.
read -r _gs _gw _gp _ge _gn _gsess <"$SFILE"
[ "$_gs" = idle ]         || fail "state not repaired to idle: [$_gs]"
[ "$_gw" = 0 ]            || fail "the window index moved: [$_gw]"
[ "$_gp" = %1 ]           || fail "the pane id moved: [$_gp]"
[ "$_ge" = 1234 ]         || fail "the epoch was rewritten: [$_ge]"
[ "$_gn" = 777 ]          || fail "the notification id was dropped: [$_gn]"
[ "$_gsess" = 'my project' ] || fail "the session name broke: [$_gsess]"
# ... then the whole line, as the backstop the per-field reads cannot be: they
# would not notice a trailing field appended after the session name, because
# `read` hands the last variable the rest of the line.
_got=$(cat "$SFILE")
[ "$_got" = "idle 0 %1 1234 777 my project" ] \
	|| fail "the repaired record is not the original with one word changed:
  got  [$_got]
  want [idle 0 %1 1234 777 my project]"

# A repair that did what it was asked is a SUCCESS. Exiting non-zero after
# fixing everything would make `mux agent-doctor --repair` unusable from a
# script, and would report failure for a run that left the box correct.
[ "$_rc" -eq 0 ] || fail "a successful repair must exit 0, got $_rc"

# ... but it still names the CAUSE. The record was wrong because a hook
# misbehaved, and a repair that only says "fixed" invites the same bug forever.
has "$_o" "--beat" "the repair did not name the cause it is papering over"
has "$_o" "at session start" "the repair did not mention hooks being resolved
once -- the reason a plugin update does not reach a running session, which is
how this bug survived two provisions"

# Twice is once: nothing left to repair, and no complaint about it.
setcpu 101 0
burn 101 0
_rc=0; _o=$(doc --repair) || _rc=$?
no_has "$_o" "REPAIRED" "a second repair claimed to fix an already-fixed record"
[ "$_rc" -eq 0 ] || fail "a second repair must be a clean no-op, got $_rc"

# --- --repair REFUSES the other two verdicts -----------------------------
# DRIFT: recorded idle, agent working. It heals on the next tool call, and the
# repair would be to write `working` -- making a finished session look busy,
# which is the direction that leaves you waiting on nothing.
agent_rec "$SFILE" idle %1 1234 alpha
setcpu 101 0
burn 101 40
_sum=$(md5sum <"$SFILE")
_rc=0; _o=$(doc --repair) || _rc=$?
has "$_o" "DRIFT" "--repair hid a drift finding"
[ "$_sum" = "$(md5sum <"$SFILE")" ] || fail "--repair rewrote a DRIFT record.
It must fix STALE and nothing else: writing working here is the worse
direction, and this one heals itself anyway."
[ "$_rc" -ne 0 ] || fail "an unrepaired drift must still exit non-zero"

# The other refusal, ORPHAN, is asserted further down instead of here, right
# after the section that establishes orphans are detected at all. Order matters
# between those two: this case presupposes detection works, so if detection
# breaks it must be the DETECTION test that goes red. Sitting here, it fired
# first and took the blame for a mutation aimed at the other one -- which
# test/mutate caught and refused to count as coverage.

# --- the compare-and-swap ------------------------------------------------
# The sample is taken BEFORE a multi-second CPU window, which is long enough for
# a real hook to fire. A record that moved in the meantime is the hooks' truth
# and this verdict is the stale one, so overwriting it would be exactly
# backwards -- and would clobber a genuine `working` with `idle`, the inversion
# this whole file exists to prevent.
agent_rec "$SFILE" working %1 1234 alpha 777
setcpu 101 0
burn 101 0
# A hook lands mid-window: same pane, NEW epoch.
( sleep 0.3; agent_rec "$SFILE" working %1 9999 alpha 777 ) &
WIN=1 _rc=0; _o=$(doc --repair) || _rc=$?
_got=$(cat "$SFILE")
[ "$_got" = "working 0 %1 9999 777 alpha" ] \
	|| fail "a record that moved during the window was clobbered: [$_got]"
no_has "$_o" "REPAIRED" "a refused swap was reported as a repair"
has "$_o" "moved during the window" "a refused swap must say why"

# --- an unknown option is an error, not a namespace ----------------------
# `mux agent-doctor --repar` must not be read as a partition called --repar:
# that reports an empty namespace and exits 0, which reads exactly like a clean
# bill of health for the partition you meant.
_rc=0; _o=$(doc --repar) || _rc=$?
[ "$_rc" -eq 2 ] || fail "an unknown option must exit 2, got $_rc: $_o"
has "$_o" "unknown option" "an unknown option did not say so"
has "$_o" "usage" "an unknown option did not print the usage"

rm -f "$T/run/agent-state/global"/*
printf 'some output\n  auto mode on . esc to interrupt . for agents\n' \
	>"$PANE_TXT"
: >"$T/share/agents/claude.agent"

# --- an agent with NO record at all --------------------------------------
# The reverse of every check above. Those audit a RECORD against reality, so
# they can only ever see a record that went wrong; an agent with no record was
# invisible, and the summary said "recorded state agrees with every agent".
#
# That is not a hypothetical reading of the code. On a live box five of seven
# sessions had a running agent and no state file -- the strip drew them as
# having no agent at all, which looks exactly like a session you never started
# one in -- and this verb called the box clean.
#
# It is the more damaging direction: a stale record shows the WRONG state but
# shows something, so the eye catches it. A missing record shows nothing, and
# nothing is indistinguishable from nothing-expected.
printf '  100     1 ksh\n  101   100 claude\n  200     1 ksh\n' >"$PSTAB"
printf '  300     1 ksh\n  301   300 claude\n' >>"$PSTAB"
printf '%%1 100 alpha\n%%2 200 beta\n%%3 300 gamma\n' >"$PANES"
rm -f "$T/run/agent-state/global"/*
agent_rec "$T/run/agent-state/global/1" idle %1 1 alpha
setcpu 101 0
setcpu 301 0
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "ORPHAN" "an agent with no state record was not surfaced"
has "$_o" "gamma" "the orphaned session was not named"
[ "$_rc" -ne 0 ] || fail "an orphaned agent must exit non-zero, got $_rc"
# The recorded pane is NOT an orphan, and neither is a pane with no agent
# under it (beta, %2 -> plain ksh); otherwise every shell pane would be
# reported. Matched per LINE: a glob over the whole output spans rows, so
# `*alpha*ORPHAN*` matches alpha's row followed by gamma's, which is a test
# that fails on correct behaviour.
if printf '%s\n' "$_o" | grep -q '^alpha .*ORPHAN'; then
	fail "a recorded session was called an orphan"
fi
if printf '%s\n' "$_o" | grep -q '^beta .*ORPHAN'; then
	fail "a pane with no agent was called an orphan"
fi
# READ-ONLY still holds on this path.
_bf=$(ls "$T/run/agent-state/global" | LC_ALL=C sort | tr '\n' ' ')
doc >/dev/null 2>&1 || true
[ "$_bf" = "$(ls "$T/run/agent-state/global" | LC_ALL=C sort | tr '\n' ' ')" ] \
	|| fail "the orphan pass changed state files"

# ... and --repair REFUSES this one, which is why it is asserted HERE rather
# than beside the other repair cases. An orphan has no record to amend, so a
# repair would have to INVENT a state from a CPU sample; "recording something
# beats nothing" is the emit path's call to make from a real lifecycle event,
# not this one's to make from a reading. Placed after the detection assertions
# above on purpose: this presupposes orphans are found at all, so a mutation
# that breaks DETECTION must be caught by the detection test, not by this one.
_rc=0; _o=$(doc --repair) || _rc=$?
has "$_o" "ORPHAN" "--repair hid an orphan finding"
[ ! -e "$T/run/agent-state/global/3" ] \
	|| fail "--repair CREATED a record for an orphan. It has no state to
copy, so any value it wrote would be a guess dressed up as a reading."
[ "$_rc" -ne 0 ] || fail "an unrepaired orphan must still exit non-zero"

# Recording it clears the finding -- the verb must be satisfiable.
agent_rec "$T/run/agent-state/global/3" idle %3 1 gamma
_rc=0; _o=$(doc) || _rc=$?
no_has "$_o" "ORPHAN" "a recorded agent was still called an orphan"
[ "$_rc" -eq 0 ] || fail "with every agent recorded the run must pass"

# Restore the two-pane world AND the exact file set the case below compares
# against ($_before, captured in the read-only section above).
printf '  100     1 ksh\n  101   100 claude\n  200     1 ksh\n' >"$PSTAB"
printf '%%1 100 alpha\n%%2 200 beta\n' >"$PANES"
rm -f "$T/run/agent-state/global"/*
agent_rec "$T/run/agent-state/global/1" idle %1 1 alpha
agent_rec "$T/run/agent-state/global/2" working %2 1 beta

# --- a pane tmux cannot resolve is not an excuse to guess ----------------
# With no pane list at all there is no agent to find, so nothing can be called
# drift -- the failure mode is silence, not a confident wrong answer.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
echo "error connecting to /tmp/tmux-1000/default" >&2
exit 1
EOF
chmod +x "$T/bin/tmux"
_rc=0; _o=$(doc) || _rc=$?
no_has "$_o" "DRIFT" "a failed pane query produced a drift verdict"
[ "$_rc" -eq 0 ] || fail "a failed pane query must not fail the run"
_after=$(ls "$T/run/agent-state/global" | LC_ALL=C sort | tr '\n' ' ')
[ "$_before" = "$_after" ] || fail "a failed pane query pruned state"

pass
