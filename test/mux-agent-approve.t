#!/bin/sh
# mux-agent-approve.t - noticing a permission prompt being APPROVED, which no
# hook reports.
#
# MEASURED on Claude Code 2.1.308: PreToolUse and PermissionRequest fire as
# the dialog appears, Notification 6s later, then nothing at all until
# PostToolUse when the approved tool finishes. A long approved command read
# `blocked` for its whole run, 7 minutes once, live. What does change is the
# process tree: the tool shell starts as a child of the agent at approval.
#
# A FABRICATED /proc, as in mux-agent-humming.t, because the rule is a shape
# in the tree plus two start times, and real processes cannot be given the
# start times that matter. MUX_HUM_PROC relocates it.
set -eu
_name=mux-agent-approve
. "$(dirname "$0")/harness_lib"
. "$HERE/lib/mux-agent-state_lib"

HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
BT=1000000
# tree NAME -> a fresh fabricated /proc for one scenario, in $P. Fresh rather
# than edited, so no scenario has to delete what the last one built.
tree() {
  P=$T/$1; mkdir -p "$P"
  printf 'cpu 1 2 3\nbtime %s\n' "$BT" >"$P/stat"
}

# proc PID PPID COMM START -> one process started at epoch START. The comm
# default carries a space and parentheses on purpose, as mux-agent-humming.t
# explains: stat does not escape either.
proc() {
  mkdir -p "$P/$1/task/$1"
  printf '%s (%s) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
    "$1" "${3:-we (ird) nam}" "$2" "$(( ($4 - BT) * HZ ))" \
    >"$P/$1/stat"
  : >"$P/$1/task/$1/children"
  [ -d "$P/$2/task/$2" ] || return 0
  printf '%s ' "$1" >>"$P/$2/task/$2/children"
}

# The pane, measured shape:
#   900 pane shell
#   `-- 910 claude, the agent
#       |-- 920 a background task's shell, started BEFORE the prompt
#       `-- 930 sh -c, the hook running emit
#           `-- 931 emit itself
EP=1005000
tree walk
proc 900 1 ksh 1001000 ; proc 910 900 claude 1001000
proc 920 910 bash 1004000 ; proc 930 910 sh "$EP" ; proc 931 930 sh "$EP"

ap() { MUX_HUM_PROC=$P mux_agent_asker "$1" "$2"; }
[ "$(ap 931 ' claude gemini ')" = 910 ] \
  || fail "the asker walk did not find the agent above the hook shell:
[$(ap 931 ' claude gemini ')]"
[ -z "$(ap 931 ' gemini ')" ] \
  || fail "the asker walk named a process that is not an agent"

REC=$T/rec
printf 'blocked 0 %%1 %s - sess\n' "$EP" >"$REC"
ok() { MUX_HUM_PROC=$P mux_agent_approved "$REC" "$EP" "$1"; }

# No .ask, no answer: a record written before this existed stays blocked.
if ok $((EP + 60)); then fail "approved with no .ask sidecar"; fi
printf '910\n' >"$REC.ask"

# THE BACKGROUND TASK IS NOT AN APPROVAL. Its shell is a child of the agent
# too, which is why the start time is the discriminator.
tree bg
proc 900 1 ksh 1001000 ; proc 910 900 claude 1001000
proc 920 910 bash 1004000
if ok $((EP + 60)); then
  fail "a background task started before the prompt read as an approval"
fi

# A HOOK IS NOT AN APPROVAL EITHER. A second Notification re-emits `blocked`
# while the dialog is still up, and its shell is a child started AFTER the
# prompt; it lives for milliseconds, which is what the age filter is for.
proc 940 910 sh $((EP + 6))
if ok $((EP + 7)); then
  fail "a one-second-old child (a hook) read as an approval"
fi

# AND THE APPROVED TOOL IS. Started after the prompt, still running.
proc 950 910 bash $((EP + 12))
ok $((EP + 20)) || fail "an approved tool's shell, started after the prompt
and 8s old, was not seen"

# Without /proc nothing is claimed: the record keeps saying blocked.
if MUX_HUM_PROC=$T/nosuch mux_agent_approved "$REC" "$EP" $((EP + 20)); then
  fail "approved with no /proc to read"
fi

# --- end to end, through the status-bar render ----------------------------
mkdir -p "$T/bin" "$T/run/mux/agent-state/global"
cat >"$T/bin/tmux" <<'STUB'
#!/bin/sh
case "$*" in
*list-sessions*) printf 'sess\n' ;;
*list-panes*)    printf '%%1\t1\t\tsess\n' ;;
*list-clients*)  printf '/dev/pts/0 161x64 sess 1\n' ;;
*client_width*)  printf '161x64 161x63 latest on\n' ;;
esac
exit 0
STUB
chmod +x "$T/bin/tmux"
R=$T/run/mux/agent-state/global/1
render() {
  env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" MUX_HUM_PROC="$P" \
    MUX_LOG="$T/log" PATH="$T/bin:$PATH" \
    "$HERE/libexec/mux-agent-state-render" sess c >/dev/null 2>&1 || true
}
# The approved tool's start must be in the past relative to the REAL clock,
# which the render reads.
NOW=$(date +%s)
EP=$((NOW - 60))
tree e2e
proc 900 1 ksh $((NOW - 3600)) ; proc 910 900 claude $((NOW - 3600))
printf 'blocked 0 %%1 %s - sess\n' "$EP" >"$R"; printf '910\n' >"$R.ask"
render
[ "$(cut -d' ' -f1 <"$R")" = blocked ] \
  || fail "the render unblocked a record whose agent has no new child"
proc 950 910 bash $((NOW - 30))
render
[ "$(cut -d' ' -f1 <"$R")" = working ] \
  || fail "the render left an approved prompt blocked: [$(cat "$R")]"
[ ! -e "$R.ask" ] || fail "the .ask sidecar outlived the prompt"
grep -q 'sess blocked -> working via approval' "$T/log" 2>/dev/null \
  || fail "the approval rewrite wrote nothing to the log:
[$(cat "$T/log" 2>/dev/null)]"

pass
