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
		"$HERE/libexec/mux-agent-doctor" global 2>&1
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
