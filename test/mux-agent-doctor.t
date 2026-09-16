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
cat >"$T/bin/ps" <<'EOF'
#!/bin/sh
printf '  100     1 ksh\n  101   100 claude\n  200     1 ksh\n'
EOF
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-panes*) printf '%%1 100\n%%2 200\n' ;;
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
printf 'idle alpha 0 %%1 1 \n' >"$T/run/agent-state/global/1"
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
printf 'working beta 0 %%2 1 \n' >"$T/run/agent-state/global/2"
rm -f "$T/run/agent-state/global/1"
_rc=0; _o=$(doc) || _rc=$?
has "$_o" "gone" "a working record with no agent process was not surfaced"

# --- READ-ONLY: it must not add, remove or alter a single state file -----
# The property the renderer did not have.
printf 'idle alpha 0 %%1 1 \n' >"$T/run/agent-state/global/1"
printf 'working beta 0 %%2 1 \n' >"$T/run/agent-state/global/2"
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
