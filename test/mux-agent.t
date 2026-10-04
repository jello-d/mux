#!/bin/sh
# test/mux-agent.t - `mux agent <verb>`, the MACHINE CONTRACT.
#
# What is asserted here is the contract itself, not the data: that every
# answer is a JSON document on STDOUT, that it carries a symbolic status, and
# that the status agrees with the exit code. The data is
# mux-agent-state-summary's
# and has its own file.
#
# THE OUTPUT IS PARSED, NEVER GREPPED. A contract checked with `grep status`
# passes on a document no parser accepts, which is precisely the failure the
# JSON emitter exists to prevent, so a test that could not see it would be
# asserting the wrong thing. python3 is the parser; without it this skips
# rather than pretending.
set -eu
_name=mux-agent
. "$(dirname "$0")/harness_lib"

command -v python3 >/dev/null 2>&1 || {
  printf 'skip %s (no python3 to parse with)\n' "$_name"; exit 0; }

XDG_RUNTIME_DIR=$T/run
MUX_DIR=$T/conf
MUX_CACHE=$T/cache
export XDG_RUNTIME_DIR MUX_DIR MUX_CACHE
mkdir -p "$XDG_RUNTIME_DIR/mux/agent-state/global" \
  "$XDG_RUNTIME_DIR/mux/agent-state/work" "$MUX_DIR/partitions" "$T/bin"

agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p1" blocked %1 100 alpha x
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p2" working %2 200 bravo x
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/work/p1"   idle    %3 300 wsess x

# THE LIVE WINDOW TOPOLOGY, one row per pane: session, window id, window
# name, pane, partition. The resolver reads membership from HERE (via the
# stub) rather than from the records above, which is the R9 fix: a record's
# window field is an INDEX, and an index is a recyclable slot.
#
# THE PARTITION COLUMN IS LOAD-BEARING, not bookkeeping. tmux's `list-panes
# -a` is per SERVER, so a stub answering every socket the same thing would
# have put `global`'s pane %7 into `work`'s listing and quietly contradicted
# the stale-pane fixture below, which needs a pane that is in no window.
PANESFILE=$T/panes; export PANESFILE
printf '%s\t%s\t%s\t%s\t%s\n' \
  alpha @1 main   %1 global \
  bravo @2 main   %2 global \
  odd   @7 odd    %7 global \
  ahead @8 ahead  %8 global \
  fresh @5 fresh  %5 global \
  alpha @9 worker %9 global \
  wsess @3 main   %3 work >"$PANESFILE"

# A RECORD WHOSE PANE IS GONE, which is a separate fixture now rather than an
# accident of the stub being thin. It used to be `wsess`, which the old stub
# simply did not list; the stub answers the live topology honestly now, so the
# case needs a pane that genuinely is not there. The two facts it proves are
# different: a live pane with no class is `human` (the default), a pane that
# does not exist is `null` (unknowable).
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/work/p7" idle %7 300 dead x

# The same one-question tmux as mux-agent-summary.t: does partition X have a
# client attached? $WATCHED is the set that does.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
# ONE STUB, DEFINED ONCE. There were two definitions of this file for a while,
# the fuller one written further down, so every assertion ABOVE it silently
# ran against a weaker tmux, and `peers` read a null class for a pane the test
# had just classified. A second definition of a fixture is a second tool, and
# which one a case gets depends on where it happens to sit.
#
# ONE ARM PER QUESTION. The client check used to run for EVERY call, and with
# $WATCHED empty its pattern `*" "*` matched `"  "`, so a capture-pane call
# got `/dev/pts/1` prepended to the pane text. A stub looser than the tool
# fails in the direction that wastes most time: the text was right and one
# line off, which reads as a bug in the verb.
_sock=
[ "${1:-}" = -L ] && _sock=$2
case "$*" in
*list-clients*)
  case " ${WATCHED:-} " in
  *" $_sock "*) printf '/dev/pts/1\n' ;;
  esac ;;
*capture-pane*)
  printf 'CAPTURED %s\n' "$*" >>"$CAPLOG"
  printf 'line one\nhe said "hi" \\ there\n' ;;
# TWO list-panes QUESTIONS NOW, SO TWO ARMS, which is this stub's own rule.
# `-a` is SERVER-WIDE (peers asks the class of every pane); `-s` is
# SESSION-SCOPED, and that is how the window resolver gets membership from
# the live server instead of from a record's window field, which is a
# recyclable INDEX. The -s arm comes first, since both match *list-panes*.
*list-panes*-s*)
  [ -z "${NOSERVER:-}" ] || exit 1
  # `_j=$*` FIRST. POSIX applies pattern removal on `$*` to EACH parameter,
  # so `${*##pat}` answers the whole argv under macOS /bin/sh (bash 3.2) and
  # the stripped first word under dash. test/lint.t refuses the shape.
  _j=$*; _ss=${_j##*-t =}; _ss=${_ss%% *}
  awk -F'\t' -v s="$_ss" -v k="$_sock" \
    '$1 == s && $5 == k { print $2 "\t" $3 "\t" $4 }' \
    "${PANESFILE:-/dev/null}" ;;
*list-panes*)
  # One line per pane: id TAB class TAB window-id TAB window-name.
  # $NOSERVER makes the query FAIL, which is a different answer from an
  # empty one and the whole reason peers reports null rather than a
  # default.
  #
  # DERIVED FROM THE SAME FIXTURE as the -s arm, so the two answers cannot
  # disagree about the topology. This file has already paid once for two
  # definitions of one fixture being two tools.
  [ -z "${NOSERVER:-}" ] || exit 1
  awk -F'\t' -v c1="${CLASS1:-}" -v c2="${CLASS2:-}" -v k="$_sock" \
    '$5 != k { next }
     { c = ""; if ($4 == "%1") c = c1; if ($4 == "%2") c = c2;
       print $4 "\t" c "\t" $2 "\t" $3 }' \
    "${PANESFILE:-/dev/null}" ;;
*window_name*)   printf '%s\n' "${WINNAME:-main}" ;;
# BEFORE the `@mux-control` arm, and that ordering is the point: a
# `set-option ... @mux-control agent` MENTIONS the option name, so the query
# arm below would answer it and swallow the write. Most specific arm first,
# which is this stub's own header rule, met again.
*set-option*)    printf 'TMUX %s\n' "$*" >>"$CAPLOG" ;;
# ATTENTION NEEDS ITS OWN ARM, and its absence made a whole case vacuous:
# `class` reads the pane's CURRENT class to decide the direction, an
# unanswered query falls back to `human`, so "escalate to human" was a
# no-op and passed whichever way the comparison ran. The corpus said so.
*@mux-attention*) printf '%s\n' "${ATTN:-}" ;;
*@mux-control*)  printf '%s\n' "${CLASS:-}" ;;
*load-buffer*|*paste-buffer*|*send-keys*|*delete-buffer*)
  printf 'TMUX %s\n' "$*" >>"$CAPLOG" ;;
# $NOSESSION makes the existence check fail, which is a DIFFERENT answer
# from "it exists and is empty" and the whole reason open exits 3.
*has-session*)
  [ -z "${NOSESSION:-}" ] || exit 1 ;;
# new-window answers with the index it made, because `open` asks the CREATE
# for it (`-P -F`) rather than querying afterwards: a follow-up query would
# be about "the current window", which `-d` has just declined to change.
# TWO FIELDS, because the create is asked for both (`-P -F '#{window_index}
# #{window_id}'`): an index is a recyclable slot, so a caller handed only one
# has nothing stable to pass back to `--window`.
*new-window*)
  printf 'TMUX %s\n' "$*" >>"$CAPLOG"
  # `NEWWID=none` answers the INDEX ALONE, which is the one-field answer the
  # create refuses: there is no fallback target, so accepting it would write
  # the class against an empty one.
  case ${NEWWID:-@3} in
  none) printf '%s\n' "${NEWIDX:-3}" ;;
  *)    printf '%s %s\n' "${NEWIDX:-3}" "${NEWWID:-@3}" ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
CAPLOG=$T/caplog; export CAPLOG
: >"$CAPLOG"

RC=0
run() {   # <args...> -> stdout in $OUT, exit in $RC
  RC=0
  OUT=$(env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" \
    MUX_CACHE="$MUX_CACHE" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PATH="$T/bin:$PATH" WATCHED="${WATCHED:-}" \
    CAPLOG="${CAPLOG:-/dev/null}" CLASS="${CLASS:-}" \
    WINNAME="${WINNAME:-main}" MUX_LOG="$T/log" \
    CLASS1="${CLASS1:-}" CLASS2="${CLASS2:-}" \
    NOSERVER="${NOSERVER:-}" NOSESSION="${NOSESSION:-}" ATTN="${ATTN:-}" \
    NEWIDX="${NEWIDX:-3}" PANESFILE="${PANESFILE:-/dev/null}" \
    NEWWID="${NEWWID:-@3}" \
    MUX_SEND_POLICY_FILE="$T/etc/send-policy" \
    "$HERE/bin/mux" agent "$@" 2>"$T/err") || RC=$?
}

# jq EXPR: evaluate a python expression over the parsed document in $OUT.
# `d` is the document. Prints the result, or fails loudly if it did not parse.
jq() {
  printf '%s' "$OUT" >"$T/doc"
  MUX_T_DOC=$T/doc MUX_T_EXPR=$1 python3 - 2>"$T/jerr" <<'PY' \
    || fail "the answer did not parse: $(cat "$T/jerr")
  got: $OUT"
import json, os, sys
raw = open(os.environ["MUX_T_DOC"]).read()
try:
    d = json.loads(raw)
except Exception as e:
    sys.stderr.write("%s: %r" % (e, raw)); sys.exit(1)
sys.stdout.write(str(eval(os.environ["MUX_T_EXPR"])))
PY
}
# $OUT IS INCLUDED, because `run` captured it and the whole point of this
# surface is that a refusal is a DOCUMENT: `{"status":"usage",...}` names the
# cause outright, so printing the exit code alone throws the answer away. macOS
# CI reported `status-rc: got [2] want [0]` for days with it sitting in hand.
# BOTH STREAMS, because they answer different questions here and `run` already
# captures each: stdout is the CONTRACT (JSON, even on failure) and stderr is
# where a failure BEFORE the JSON machinery lands. macOS reported `got [2]` with
# an empty stdout, which says only "it never reached the document", and the
# reason was sitting in $T/err unread.
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]
mux stdout: ${OUT:-<nothing>}
mux stderr: $(cat "$T/err" 2>/dev/null || true)"; }

# `read` is a mux VERB here, not the shell builtin, but shellcheck sees the
# word after a wrapper function and assumes the builtin, at every call site.
# One helper carries the suppression so a real `read` anywhere else in this
# file still fails, which is this project's rule for an intentional-but-rare
# exception.
# shellcheck disable=SC2162
_read() { run read "$@"; }

# --- the happy answer -----------------------------------------------------
WATCHED=global run status; unset WATCHED
eq status-rc "$RC" 0
eq status-ok "$(jq 'd["status"]')" ok
eq status-parts "$(jq 'len(d["partitions"])')" 1
eq status-name "$(jq 'd["partitions"][0]["partition"]')" global
eq status-state "$(jq 'd["partitions"][0]["state"]')" blocked
# A NUMBER, not a string. That is most of the point of JSON over the
# tab-separated form: a consumer gets a type instead of an agreement.
eq status-count "$(jq 'd["partitions"][0]["count"] + 1')" 2

# --- SCOPED TO THE CALLER'S PARTITION BY DEFAULT --------------------------
# `_all` was PARSED AND NEVER READ until 0.73, so every caller got every
# partition and the flag was decoration. The shipped skill says the opposite,
# one sentence after calling a partition an isolation boundary, so an agent
# in `work` reading `status` was told it was seeing its own partition while
# being handed `global`'s state and counts.
#
# The old assertion here encoded the bug: it asserted `--any` returned BOTH
# partitions, which was true only because nothing was scoping. A flag that
# parses and does nothing is worse than a missing one, because the caller
# believes it asked for something.
WATCHED=global run status --any; unset WATCHED
eq scoped-default "$(jq 'len(d["partitions"])')" 1
eq scoped-is-mine "$(jq 'd["partitions"][0]["partition"]')" global

# --all WIDENS, which is the direction the tray depends on: a reader on
# another box cannot know the partition names to ask for.
WATCHED=global run status --all --any; unset WATCHED
eq all-widens "$(jq 'len(d["partitions"])')" 2

# --partition SELECTS one that is not mine, and is the flag the skill
# documents and the verb did not parse at all.
WATCHED=global run status --partition work --any; unset WATCHED
eq part-selects "$(jq 'len(d["partitions"])')" 1
eq part-is-named "$(jq 'd["partitions"][0]["partition"]')" work
# `run` captures the status into $RC, so `$?` here reads the WRAPPER and is 0
# whatever the verb did: the same shape as the vacuous assertions this suite
# has been bitten by before.
run status --partition
eq part-needs-a-name "$RC" 2
eq part-needs-a-name-says "$(jq 'd["status"]')" usage

# --- ATTACHED BY DEFAULT, --any for everything ----------------------------
# A tray item means somebody is looking at it, and an agent asking what is
# going on wants the answer a human would see. Asserted IN SCOPE, so it cannot
# be confused with the scoping above: the caller's own partition, with and
# without a client attached to it.
WATCHED=global run status; unset WATCHED
eq default-hides-unwatched "$(jq 'len(d["partitions"])')" 1
WATCHED= run status --any; unset WATCHED
eq any-shows-unattached "$(jq 'len(d["partitions"])')" 1

# --- NOTHING WATCHED IS AN EMPTY ARRAY, NOT AN ERROR ----------------------
# The JSON form of "empty is exit 0": a box where nobody is attached answers
# the same SHAPE as one with five partitions, so a consumer never has to tell
# a quiet answer from a broken one by looking at the exit code alone.
WATCHED= run status; unset WATCHED
eq empty-rc "$RC" 0
eq empty-ok "$(jq 'd["status"]')" ok
eq empty-arr "$(jq 'len(d["partitions"])')" 0

# --- peers: every session, and what it is doing ---------------------------
# The verb an agent reaches for first. HEADLESS by construction (sessions
# come from the state FILES and roots from the session set), so it answers
# over a transport, at boot, with no tmux client and no server attached.
# $MUX_STATE, which harness_lib already pins and exports for exactly this. Two
# wrong guesses first, and both failed the same silent way (an empty root,
# no error), which is why the assertion below is on the root and not merely
# on the peer being present: XDG_STATE_HOME (which `run` does not pass
# through) and $HOME/.local/state/mux (which MUX_STATE overrides).
printf 'alpha	/srv/alpha
bravo	/srv/bravo
' >"$MUX_STATE/sessions.global"
printf 'wsess	/srv/wsess
' >"$MUX_STATE/sessions.work"

run peers
eq peers-rc "$RC" 0
eq peers-ok "$(jq 'd["status"]')" ok
eq peers-n "$(jq 'len(d["peers"])')" 2
eq peers-names "$(jq 'sorted(p["session"] for p in d["peers"])')" \
  "['alpha', 'bravo']"
eq peers-state \
  "$(jq '[p["state"] for p in d["peers"] if p["session"]=="alpha"][0]')" \
  blocked
# THE ROOT COMES FROM THE SESSION SET, which is a different source from the
# state files, and sourcing mux-sessions_lib without mux-paths_lib gave every
# peer an empty root plus six `mux_state_path: not found` lines on stderr. A
# plausible answer, silently wrong: exactly the lib-needs-a-lib trap.
eq peers-root \
  "$(jq '[p["root"] for p in d["peers"] if p["session"]=="alpha"][0]')" \
  /srv/alpha

# AGE, NOT AN EPOCH, resolved against the clock that wrote it. The obvious
# design emits the epoch and works until the reader is on another machine,
# where a box a few seconds off shows "idle 4s" as "idle 2m" and one badly off
# shows a negative.
#
# ASSERTED WITH A FRESH RECORD, because the fixtures above use epoch 100 and
# would make a leaked epoch and a genuine 55-year age indistinguishable. This
# one was written just now, so an age is single digits and an epoch is 1.7
# billion: no threshold to tune, and the two cannot be confused.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p9" idle %5 \
  "$(date +%s)" fresh x
printf 'fresh	/srv/fresh
' >>"$MUX_STATE/sessions.global"
run peers
eq peers-age-number "$(jq 'type(d["peers"][0]["age"]).__name__')" int
eq peers-age-sane "$(jq 'all(p["age"] >= 0 for p in d["peers"])')" True
# A record stamped in the FUTURE, which is what the clamp exists for: this
# host's clock moved, and "0" is the honest floor for "it began no earlier
# than now". Without a case for it the clamp is a guard nothing can kill.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p8" idle %8 \
  "$(( $(date +%s) + 3600 ))" ahead x
printf 'ahead\t/srv/ahead\n' >>"$MUX_STATE/sessions.global"
run peers
eq peers-clamped \
  "$(jq '[p["age"] for p in d["peers"] if p["session"]=="ahead"][0]')" 0
eq peers-age-is-age \
  "$(jq '[p["age"] for p in d["peers"] if p["session"]=="fresh"][0] < 60')" \
  True

# --- peers reports WHO CONTROLS each pane ---------------------------------
# So a caller can see the classification without attempting a send and reading
# the refusal. One tmux query per PARTITION rather than per peer.
CLASS2=agent run peers; unset CLASS2
eq peers-class-default \
  "$(jq '[p["control"] for p in d["peers"] if p["session"]=="alpha"][0]')" \
  human
eq peers-class-agent \
  "$(jq '[p["control"] for p in d["peers"] if p["session"]=="bravo"][0]')" \
  agent

# NULL IS NOT `human`, and that distinction is the point. With no server
# reachable (a remote `peers` at boot, which this verb is designed for),
# every pane would otherwise report as human-controlled: plausible, and wrong.
# peers still ANSWERS, because it derives its sessions from the state files.
NOSERVER=1 run peers; unset NOSERVER
eq peers-headless-rc "$RC" 0
eq peers-headless-n "$(jq 'len(d["peers"])')" 4
eq peers-headless-null "$(jq 'all(p["control"] is None for p in d["peers"])')" \
  True
# ... and the rest of the answer is unaffected, which is what makes it a
# missing FIELD rather than a missing answer.
eq peers-headless-state \
  "$(jq '[p["state"] for p in d["peers"] if p["session"]=="alpha"][0]')" \
  blocked

# A PANE THAT IS GONE but whose record is not: the class is unknowable, which
# is null rather than the default. `dead` records pane %7, which is in no
# window of the live listing.
CLASS2=agent run peers --partition work; unset CLASS2
# STATUS BEFORE PAYLOAD, at the FIRST use of the flag. This is the rule the
# contract gives a consumer, and it is what makes a failure legible: a mutation
# that removed the `--partition` arm answers `{"status":"usage"}` (valid JSON
# with no `peers` key), so every assertion below raises inside the helper and
# the kill lands on "the answer did not parse: Traceback" rather than on
# anything named. Guarding only the later use was not enough, because this one
# runs first; the full corpus said so both times.
eq peers-part-status "$(jq 'd["status"]')" ok
eq peers-stale-pane \
  "$(jq '[p["control"] for p in d["peers"] if p["session"]=="dead"][0]')" \
  None
# AND THE CONTROL BESIDE IT, or the case passes for a fixture that cannot
# fail: a live pane in the same partition must still report its class.
eq peers-live-pane-not-null \
  "$(jq '[p["control"] for p in d["peers"] if p["session"]=="wsess"][0]')" \
  human

# --- peers is scoped to ONE partition, and --all widens it ----------------
run peers
eq peers-n-after "$(jq 'len(d["peers"])')" 4
eq peers-scoped "$(jq 'set(p["partition"] for p in d["peers"])')" "{'global'}"
run peers --partition work
# STATUS FIRST, THEN THE PAYLOAD, which is the rule the contract itself gives a
# consumer and the reason this assertion exists: a mutation that removed the
# `--partition` arm answered `{"status":"usage"}` (valid JSON with no `peers`
# key), so the helper raised and the kill landed on "the answer did not parse:
# Traceback" rather than on anything named. The full corpus reported it as a
# record dying for the wrong reason, which is the driver doing its job.
eq peers-other-status "$(jq 'd["status"]')" ok
eq peers-other-n "$(jq 'len(d["peers"])')" 2
eq peers-other "$(jq 'set(p["partition"] for p in d["peers"])')" "{'work'}"
run peers --all
eq peers-all "$(jq 'sorted(set(p["partition"] for p in d["peers"]))')" \
  "['global', 'work']"

# An unknown partition is not an error here: it has no sessions, so it has no
# peers, and `[]` is an answer. Inventing a refusal would make a caller
# distinguish "empty" from "wrong" for a question with one honest answer.
run peers --partition nosuchpartition
eq peers-unknown-rc "$RC" 0
eq peers-unknown-n "$(jq 'len(d["peers"])')" 0

run peers --nosuchoption
eq peers-badopt-rc "$RC" 2
eq peers-badopt "$(jq 'd["status"]')" usage
run peers --partition
eq peers-bare-part-rc "$RC" 2
eq peers-bare-part "$(jq '"needs a name" in d["message"]')" True

# --- read: what is on that agent's screen ---------------------------------
# THE PANE IS RESOLVED NOW, from the state record, rather than taken from a
# caller. An id cached from an earlier `peers` can have died and been replaced,
# and capturing the wrong pane is the plausible-wrong-answer shape.

_read alpha
eq read-rc "$RC" 0
eq read-ok "$(jq 'd["status"]')" ok
eq read-session "$(jq 'd["session"]')" alpha
# The pane comes from the RECORD, so it is the pane the agent is actually in.
eq read-pane "$(jq 'd["pane"]')" %1
# A SECOND SESSION, WITH A DIFFERENT PANE, because the first one's pane is %1
# and a hardcoded %1 passes every assertion about it. Mutation said so: the
# resolver was replaced by a constant and nothing noticed.
_read bravo
eq read-pane-other "$(jq 'd["pane"]')" %2
grep -q 'CAPTURED -L ' "$CAPLOG" \
  || fail "read captured from the DEFAULT tmux socket, not the
partition's: $(cat "$CAPLOG")"
# AND THE TEXT SURVIVES A ROUND TRIP, quotes and backslash included. This is
# the first verb whose payload is arbitrary terminal output, which is exactly
# the input the JSON escaper exists for.
eq read-text "$(jq 'd["text"].splitlines()[1]')" 'he said "hi" \ there'

# THE VISIBLE PANE BY DEFAULT, scrollback only when asked: an agent pane's
# scrollback can be enormous, and a verb whose default answer is unbounded is
# one a caller learns to be afraid of.
grep -q 'capture-pane -p -J -t %1$' "$CAPLOG" \
  || fail "the default capture asked for scrollback: $(cat "$CAPLOG")"
: >"$CAPLOG"
_read alpha -n 50
grep -q -- '-S -50' "$CAPLOG" \
  || fail "-n did not reach capture-pane: $(cat "$CAPLOG")"

# AN OPTION IS AN OPTION WHEREVER IT SITS. The front end stops parsing at the
# first positional, which is tolerable for a human who can see the result and
# not for a caller composing argv, where order becomes a rule nobody wrote
# down. `mux agent read mux -n 5` failed exactly that way once.
: >"$CAPLOG"
_read -n 50 alpha
eq read-opt-before "$RC" 0
grep -q -- '-S -50' "$CAPLOG" || fail "an option before the session was lost"

_read nosuchsession
eq read-unknown-rc "$RC" 3
eq read-unknown "$(jq 'd["status"]')" no-such-name
_read
eq read-noargs-rc "$RC" 2
_read alpha bravo
eq read-two-rc "$RC" 2
eq read-two "$(jq '"one SESSION" in d["message"]')" True
_read alpha -n x
eq read-badn-rc "$RC" 2

# --- wait: block until it gets there --------------------------------------
# ALREADY THERE RETURNS AT ONCE, rather than after the first poll interval.
run wait alpha blocked -t 5
eq wait-rc "$RC" 0
eq wait-ok "$(jq 'd["status"]')" ok
eq wait-waited "$(jq 'd["waited"] < 3')" True

# TIMED-OUT IS ITS OWN STATUS AND NOT ITS OWN EXIT CODE, which is the whole
# argument for carrying both: "it did not happen in time" is a refusal as far
# as a shell is concerned, and a reader that wants to tell it from every other
# refusal reads the word. Widening mux's four codes would cost latch the
# attribution it gets from 126, 127 and 255 never being mux's.
# BOUNDED BY THE TEST, not just by the verb, because the guard under test IS
# the verb's bound: mutate it away and an unbounded loop hangs the suite
# instead of failing it. `timeout` turns "the guard is gone" into a verdict,
# which is the same shape mux-latch-stall.t uses for its own stalled peers.
RC=0
OUT=$(env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" MUX_CACHE="$MUX_CACHE" \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH="$T/bin:$PATH" \
  CAPLOG="${CAPLOG:-/dev/null}" \
  timeout 20 "$HERE/bin/mux" agent wait alpha idle -t 1 2>"$T/err") \
  || RC=$?
[ "$RC" != 124 ] || fail "wait never returned: its timeout is not bounding
anything, so a caller asking about a session that never changes hangs forever"
eq wait-to-rc "$RC" 1
eq wait-to-status "$(jq 'd["status"]')" timed-out
# AND IT REPORTS THE STATE IT IS ACTUALLY IN: "not idle yet" is a different
# problem from "blocked and waiting for a human", and a caller that has just
# burned its timeout should not need a second round trip to find out which.
eq wait-to-state "$(jq 'd["state"]')" blocked
eq wait-to-wanted "$(jq 'd["wanted"]')" idle

run wait nosuchsession idle -t 1
eq wait-unknown-rc "$RC" 3
eq wait-unknown "$(jq 'd["status"]')" no-such-name
# A STATE MUX NEVER EMITS is a usage error, not a wait that can never end.
run wait alpha nosuchstate -t 1
eq wait-badstate-rc "$RC" 2
eq wait-badstate "$(jq '"not a state" in d["message"]')" True
run wait alpha
eq wait-noargs-rc "$RC" 2
run wait alpha idle -t x
eq wait-badt-rc "$RC" 2

# --- send: the hook a higher layer needs ----------------------------------
# mux already knows which pane is the agent's, which partition it is in, and
# (the part only mux knows) whether it is BLOCKED. Without this verb an
# orchestrator reaches around mux to `tmux send-keys`, re-derives pane
# resolution, and inherits none of the guards below.
mkdir -p "$T/etc"
seal_pol() { chmod 0444 "$T/etc/send-policy"; chmod 0555 "$T/etc"; }
# pol LINE: replace the policy and seal it, which four cases below do.
pol() { unseal_pol; printf '%s\n' "$1" >"$T/etc/send-policy"; seal_pol; }
unseal_pol() { chmod 0755 "$T/etc" 2>/dev/null || true
  chmod 0644 "$T/etc/send-policy" 2>/dev/null || true; }
t_trap 'chmod 0755 "$T/etc" 2>/dev/null || true'

# `bravo` is WORKING, which needs no override: a turn that is running buffers
# the text and picks it up when it ends. That is the natural "queue the next
# instruction" case, and refusing it would make every caller poll for idle.
: >"$CAPLOG"
run send bravo 'hello there'
eq send-rc "$RC" 0
eq send-ok "$(jq 'd["status"]')" ok
eq send-pane "$(jq 'd["pane"]')" %2
eq send-bytes "$(jq 'd["bytes"]')" 11

# BRACKETED PASTE, so the TUI sees pasted text rather than a stream of
# keystrokes. Anything multi-line would otherwise submit its first line alone
# and leave the rest arriving as a fresh prompt.
grep -q 'paste-buffer -p ' "$CAPLOG" \
  || fail "the text was not pasted in BRACKETED mode: $(cat "$CAPLOG")"
# ... into a buffer named for this process and deleted on paste, so a human's
# own tmux buffers are not clobbered by an agent talking to a peer.
grep -q 'paste-buffer .*-d ' "$CAPLOG" \
  || fail "the staging buffer was not deleted: $(cat "$CAPLOG")"
grep -q 'send-keys .*Enter' "$CAPLOG" || fail "Enter was never sent"

# EVERY tmux CALL NAMES THE PARTITION'S SOCKET. A bare `tmux` asks the DEFAULT
# one, which is not where a partition's server lives, so `send` read an
# empty class for a pane plainly marked `agent` and refused it as a human's,
# and `read` captured nothing. Both looked like correct refusals, which is why
# only a REAL server caught it. Third time this repo has paid for it, after
# mux-even and next-blocked, so it is asserted rather than remembered.
grep -q 'TMUX -L ' "$CAPLOG" \
  || fail "send talked to the DEFAULT tmux socket instead of the
partition's: $(cat "$CAPLOG")"

: >"$CAPLOG"
run send bravo 'no newline' --no-enter
grep -q 'send-keys .*Enter' "$CAPLOG" \
  && fail "--no-enter still pressed Enter: $(cat "$CAPLOG")"

# STDIN, so a long charge is not an argv-length problem.
_o=$(printf 'from stdin' | env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" \
  MUX_CACHE="$MUX_CACHE" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  PATH="$T/bin:$PATH" CAPLOG="$CAPLOG" \
  "$HERE/bin/mux" agent send bravo - 2>&1)
case $_o in
*'"bytes":10'*) ;;
*) fail "the stdin form did not read the text: [$_o]" ;;
esac

# --- BLOCKED: mux will not answer a prompt on a human's behalf ------------
# `alpha` is blocked. With no class set the pane is a HUMAN's: the safe
# answer is the one you get by saying nothing.
run send alpha 'y'
eq blk-rc "$RC" 1
eq blk-status "$(jq 'd["status"]')" refused
eq blk-reason "$(jq 'd["reason"]')" blocked
eq blk-class "$(jq 'd["class"]')" human
# NO OVERRIDE EXISTS FOR A HUMAN PANE, and the policy is never consulted.
eq blk-override "$(jq 'd["override"]')" none
eq blk-msg "$(jq '"human-controlled" in d["message"]')" True

# ... and the acknowledgement alone changes nothing, which is the property
# that makes a forgeable flag safe to have: it grants nothing on its own.
run send alpha 'y' --answer-prompt
eq blk-ack-rc "$RC" 1
eq blk-ack-override "$(jq 'd["override"]')" none

# --- an AGENT-CONTROLLED pane, with no policy -----------------------------
# The class alone is not permission either. Both halves are required.
CLASS=agent run send alpha 'y' --answer-prompt; unset CLASS
eq agent-nopol-rc "$RC" 1
eq agent-nopol-override "$(jq 'd["override"]')" none

# --- the policy grants the CLASS: now the capability is reported ----------
# A caller that does not know discovers it in one round trip and decides; one
# that does know passes the flag up front and pays nothing. That signal is why
# there is no standing always-open grant.
pol 'send-blocked control:agent'
CLASS=agent run send alpha 'y'; unset CLASS
eq grant-rc "$RC" 1
eq grant-override "$(jq 'd["override"]')" available
eq grant-msg "$(jq '"--answer-prompt" in d["message"]')" True

# ... and WITH the acknowledgement it goes through.
: >"$CAPLOG"
CLASS=agent run send alpha 'y' --answer-prompt; unset CLASS
eq grant-ack-rc "$RC" 0
eq grant-ack-status "$(jq 'd["status"]')" ok
grep -q 'paste-buffer' "$CAPLOG" || fail "the override did not send"

# A HUMAN PANE IS STILL NEVER GRANTED, even by a policy that is in force. The
# class gate runs BEFORE the allowlist, so a grant naming only a window cannot
# reach a human's pane by omission.
pol 'send-blocked *'
run send alpha 'y' --answer-prompt
eq human-star-rc "$RC" 1
eq human-star-override "$(jq 'd["override"]')" none

# HYBRID IS ITS OWN CLASS and is NOT covered by an agent grant: folding it
# into either neighbour was the wrong answer in both directions.
pol 'send-blocked control:agent'
CLASS=hybrid run send alpha 'y' --answer-prompt; unset CLASS
eq hybrid-rc "$RC" 1
eq hybrid-override "$(jq 'd["override"]')" none
pol 'send-blocked control:hybrid'
CLASS=hybrid run send alpha 'y' --answer-prompt; unset CLASS
eq hybrid-granted-rc "$RC" 0

# --- the two acknowledgements are SEPARATE --------------------------------
# Being allowed to answer prompts must never imply being allowed to type into
# a pane mux cannot classify.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p7" weirdstate %7 100 odd x
printf 'odd\t/srv/odd\n' >>"$MUX_STATE/sessions.global"
pol 'send-blocked control:agent'
CLASS=agent run send odd 'x' --answer-prompt; unset CLASS
eq unk-rc "$RC" 1
eq unk-reason "$(jq 'd["reason"]')" unknown
eq unk-override "$(jq 'd["override"]')" none
# ... and with the `unknown` grant in force, the ACKNOWLEDGEMENT is still
# required. Asserted separately from the grant, or the policy check covers for
# the ack check and neither is individually killable, which is exactly what
# mutation reported here.
pol 'send-unknown control:agent'
CLASS=agent run send odd 'x'; unset CLASS
eq unk-noack-rc "$RC" 1
eq unk-noack-override "$(jq 'd["override"]')" available
eq unk-noack-msg "$(jq '"--blind" in d["message"]')" True
CLASS=agent run send odd 'x' --blind; unset CLASS
eq unk-granted-rc "$RC" 0

# --- every send that lands is LOGGED --------------------------------------
# A send is a mutation, and the one mux makes on another agent's behalf. It is
# also the audit trail the layer above would otherwise have to build.
grep -q 'send\[' "$T/log" 2>/dev/null \
  || fail "a send was not logged: [$(cat "$T/log" 2>/dev/null)]"
grep -q 'odd' "$T/log" || fail "the log did not name the session"
unseal_pol

run send bravo
eq send-noargs-rc "$RC" 2
run send bravo a b
eq send-three-rc "$RC" 2

# --- FAILURE IS STILL JSON, AND STILL ON STDOUT ---------------------------
# The promise that makes this a contract rather than a convention. Every other
# mux verb puts its reason on stderr, which is right for a human and wrong for
# a caller that parses: a reader here never has to decide whether today's
# answer is a document or a sentence.
run nosuchverb
eq badverb-rc "$RC" 2
eq badverb-status "$(jq 'd["status"]')" usage
eq badverb-msg "$(jq '"nosuchverb" in d["message"]')" True
[ ! -s "$T/err" ] || fail "the refusal went to STDERR as well as stdout, so a
caller that reads one stream gets half the answer: $(cat "$T/err")"

run status --nosuchoption
eq badopt-rc "$RC" 2
eq badopt-status "$(jq 'd["status"]')" usage

run
eq noverb-rc "$RC" 2
eq noverb-status "$(jq 'd["status"]')" usage

# --- the status word AGREES with the exit code ----------------------------
# Several statuses may share a code (that is why both exist), but a status
# must not be able to mean two different exits, or a reader that switches on
# one will disagree with a shell that switches on the other.
for _case in 'nosuchverb usage 2' 'status ok 0'; do
  # shellcheck disable=SC2086   # three words per entry, split on purpose
  set -- $_case
  WATCHED=global run "$1"; unset WATCHED
  eq "agree-$1-rc" "$RC" "$3"
  eq "agree-$1-status" "$(jq 'd["status"]')" "$2"
done

# --- mux's exit-code contract is NOT widened ------------------------------
# The whole reason richer outcomes live in the payload: mux uses exactly four
# codes and the ABSENCE of every other one is load-bearing, because latch
# attributes 126, 127 and 255 to the shell and to ssh precisely because mux
# never emits them.
for _args in 'status' 'nosuchverb' 'status --nope' ''; do
  # shellcheck disable=SC2086   # deliberate word split
  WATCHED=global run $_args; unset WATCHED
  case $RC in
  0|1|2|3) ;;
  *) fail "\`mux agent $_args\` exited $RC, outside mux's four codes.
126, 127 and 255 must stay attributable to the shell and to ssh" ;;
  esac
done

# --- A SEND MAY NOT CROSS A PARTITION BOUNDARY ---------------------------
# FOUND BY THE USER ASKING whether mux pokes a hole in the boundary a
# partition mechanism exists to keep. It did. Every token on a policy line is
# ANDed, so `send-blocked control:agent`, the one grant that makes a village
# of generated worker names workable at all, carries NO partition token and
# therefore reached agents in EVERY partition.
#
# AND THE CROSSING IS REAL. A partition is a tmux `-L` socket owned by the
# login user, so same-uid means full reach; where the boundary is a GROUP
# acquired per session, the pane on the other side HOLDS that group and
# typing into it runs commands with privileges this side was refused.
#
# `wsess` IS THE RIGHT FIXTURE PRECISELY BECAUSE IT IS `idle`: idle and
# working bypass the override machinery entirely, which is how my first
# version of the gate (inside `_refuse`) guarded the two rare states and
# missed the common one. A fixture in a blocked state would have passed
# against that broken code.
WATCHED=global run send wsess 'rm -rf /' --partition work; unset WATCHED
eq "cross-rc" "$RC" 1
eq "cross-status" "$(jq 'd["status"]')" refused
eq "cross-reason" "$(jq 'd["reason"]')" cross-partition
# NO OVERRIDE EXISTS, and that is the point of the field: there is
# deliberately no flag and no policy token that opens this, so a caller
# discovering the refusal must not be told to go and ask for a grant.
eq "cross-override" "$(jq 'd["override"]')" none

# AND IT IS NOT MERELY REPORTED: nothing may reach the pane. Asserted on the
# capture log rather than on the verdict, because a refusal that prints the
# right JSON after already pasting the text is the one failure that matters
# here, and no status assertion can see it.
# CAPLOG IS RESTORED, NOT UNSET, and that distinction is a real trap in the
# `VAR=x func; unset VAR` idiom this suite adopted for the macOS leak. The
# idiom is only safe for a name that is OTHERWISE UNSET: `CAPLOG` has a
# legitimate value set at the top of this file, the prefix merely shadows it
# for one call, and `unset` therefore destroyed the file's own global. It went
# unnoticed because nothing after this line read CAPLOG until a case was
# appended months later, which then died with `CAPLOG: parameter not set`
# about a variable assigned 600 lines above.
CAPLOG=$T/crosslog WATCHED=global run send wsess 'rm -rf /' \
  --partition work --answer-prompt --blind
CAPLOG=$T/caplog; unset WATCHED
[ ! -s "$T/crosslog" ] || fail "text was sent into another partition even
though the call was refused, and the override flags must not be a way
through: [$(cat "$T/crosslog")]"

# THE SAME-PARTITION CASE MUST STILL WORK, or the gate is just a break.
# Asserted in both directions because they are different bugs: crossing is a
# boundary hole, refusing your own partition is the feature deleted.
CLASS=agent run send bravo 'still fine'; unset CLASS
eq "same-partition-rc" "$RC" 0

# A FAILED CONTEXT COMMAND REFUSES rather than assuming the baseline, because
# `mux_ctx_resolve` answers 0 with `global` for a hook that EXITED NON-ZERO
# (measured), so its status alone cannot tell "no hook" from "the hook
# broke". Failing OPEN is the one answer an actuating verb must never give.
printf '#!/bin/sh\nexit 1\n' >"$MUX_DIR/ccfail"
chmod +x "$MUX_DIR/ccfail"
cp "$MUX_DIR/config" "$T/config.keep" 2>/dev/null || : >"$T/config.keep"
printf 'context-command ccfail\n' >"$MUX_DIR/config"
CLASS=agent run send bravo 'should not land'; unset CLASS
eq "ctxfail-rc" "$RC" 1
eq "ctxfail-reason" "$(jq 'd["reason"]')" cross-partition
cp "$T/config.keep" "$MUX_DIR/config"



# --- `open`: a WINDOW in an existing session, and what it is for ----------
# vicus's R8. Without this verb the layer above reimplements it, and did: its
# one documented exemption from "never sidestep mux to reach tmux" omitted
# `-d`, so every worker it spawned dragged the human's view into the worker.
: >"$CAPLOG"
run open alpha --name build-1 --dir "$T" --cmd 'make watch' \
  --control agent --attention agent
[ "$RC" = 0 ] || fail "open failed: rc=$RC $(cat "$T/err") $OUT"
eq "open-status" "$(jq 'd["status"]')" ok
eq "open-window" "$(jq 'd["window"]')" 3
# AND THE STABLE HANDLE. The index is for display; this is what `--window`
# takes, and without it a caller would have to go back through `peers` to
# address the window it had just created.
eq "open-window-id" "$(jq 'd["window_id"]')" @3
eq "open-session" "$(jq 'd["session"]')" alpha
eq "open-control" "$(jq 'd["control"]')" agent
eq "open-attention" "$(jq 'd["attention"]')" agent

# DETACHED, ALWAYS, on this surface. THE LOAD-BEARING ASSERTION of the verb:
# a machine call that moves the human's view mid-turn is an interrupt nobody
# asked for, and it is the exact defect the hand-rolled copy had.
case "$(cat "$CAPLOG")" in
*'new-window'*' -d '*) ;;
*) fail "open did not pass -d, so tmux SELECTED the new window and the
human's view followed a worker: $(cat "$CAPLOG")" ;;
esac
# The target is anchored, or `alpha` would match `alpha-2`: the bug this
# codebase has shipped four times.
case "$(cat "$CAPLOG")" in
*'new-window -t =alpha'*) ;;
*) fail "open did not anchor the session target: $(cat "$CAPLOG")" ;;
esac
# And both classes are declared on the window it just made, not on whatever
# pane happened to be current.
#
# BY ID, NOT BY INDEX, which is the one thing that can go wrong between the
# create and this write: an index renumbers (`renumber-windows`, or a
# concurrent kill), and the declaration then lands on somebody else's pane.
# Measured that `set-option -p -t @N` resolves that window's active pane and
# leaves the neighbouring window untouched.
case "$(cat "$CAPLOG")" in
*'set-option -p -t @3 @mux-control agent'*) ;;
*) fail "the control class was not set on the new window BY ID:
$(cat "$CAPLOG")" ;;
esac
case "$(cat "$CAPLOG")" in
*'set-option -p -t @3 @mux-attention agent'*) ;;
*) fail "attention was not set on the new window: $(cat "$CAPLOG")" ;;
esac

# A ONE-FIELD ANSWER IS REFUSED. The create asks tmux for the index AND the
# id, so a server answering one is incoherent rather than old, and there is
# deliberately no fallback to the index: that fallback could not be reached
# by any live tmux, so it would be an unkillable guard, and this package's
# rule for those is to delete the code rather than test harder.
: >"$CAPLOG"
NEWWID=none run open alpha --name w; unset NEWWID
[ "$RC" = 2 ] || fail "a create that named no window id must refuse,
got rc=$RC: $OUT"
eq "open-halfanswer" "$(jq '"did not say which" in d["message"]')" True
# AND IT DECLARED NOTHING, which is the half that matters: a class written
# against an empty target is the plausible-wrong-answer shape.
case "$(cat "$CAPLOG")" in
*set-option*) fail "it refused the create and set a class anyway:
$(cat "$CAPLOG")" ;;
esac

# IT NEVER CREATES A SESSION, which is a different job (`mux go`). A missing
# one is `no-such-name` and exit 3, mux's existing cross-cutting code for the
# condition, so a caller that mistyped a session does not get a surprise one.
NOSESSION=1; export NOSESSION
run open nosuch --name w
[ "$RC" = 3 ] || fail "open on a missing session must exit 3, got $RC: $OUT"
eq "open-missing" "$(jq 'd["status"]')" no-such-name
unset NOSESSION

# A CLASS IS ONE OF THREE WORDS. An unknown one is refused rather than
# recorded: every reader falls through to `human`, so the call would read as a
# grant and behave as a refusal.
run open alpha --control supervisor
[ "$RC" = 2 ] || fail "a bad class must exit 2, got $RC: $OUT"
eq "open-badclass" "$(jq 'd["status"]')" usage

# A WINDOW NAME MAY NOT CONTAIN A COLON, for the same reason a session name
# may not: the address grammar spends `:` on the window separator, so such a
# window is unaddressable by the grammar that would name it.
run open alpha --name 'a:b'
[ "$RC" = 2 ] || fail "a colon in a window name must exit 2, got $RC: $OUT"

# AND IT REFUSES TO CROSS A PARTITION, which it must do HARDER than `send`:
# send types into a pane that exists, open RUNS A COMMAND, and where a
# partition's boundary is a group acquired per session the children of that
# server hold it. No flag and no policy token opens this.
printf 'label work\n' >"$MUX_DIR/partitions/work.partition"
run open wsess --partition work --name w
[ "$RC" = 1 ] || fail "a cross-partition open must exit 1, got $RC: $OUT"
eq "open-cross" "$(jq 'd["status"]')" refused
eq "open-cross-reason" "$(jq 'd["reason"]')" cross-partition
eq "open-cross-override" "$(jq 'd["override"]')" none

# --- `peers` reports per WINDOW ------------------------------------------
# vicus's R4, and the half of R8 a session-level answer cannot give: a worker
# is a WINDOW in the session it serves, so collapsing a session to its worst
# agent cannot say whether THIS worker is live.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p9" idle %9 400 alpha x
python3 - "$XDG_RUNTIME_DIR/mux/agent-state/global/p9" <<'PY'
import sys
# agent_rec writes window 0; this record is the SECOND window of alpha, and
# the window field is what the per-window answer is about.
p = sys.argv[1]
f = open(p).read().split()
f[1] = "7"
open(p, "w").write(" ".join(f) + "\n")
PY
run peers
[ "$RC" = 0 ] || fail "peers failed: $OUT"
_wq='sorted(str(x["window"]) for x in d["peers"]'
_wq="$_wq"' if x["session"]=="alpha")'
eq "peers-windows" "$(jq "$_wq")" "['0', '7']"
eq "peers-win-state" \
  "$(jq '[x["state"] for x in d["peers"] if x["window"]==7][0]')" idle
_sq='[x["state"] for x in d["peers"]'
_sq="$_sq"' if x["session"]=="alpha" and x["window"]==0][0]'
eq "peers-win0-state" "$(jq "$_sq")" blocked
rm -f "$XDG_RUNTIME_DIR/mux/agent-state/global/p9"


# --- `class`: R3, the transition that is ESCALATION -----------------------
# vicus's R3: "the answer can change during a session's life, and the surfaces
# follow it without the agent being restarted". A supervisor that cannot
# resolve something hands it to the human, and at that instant the worker must
# become visible on the human's surfaces, so a value fixed at creation cannot
# express it.
#
# ONE WAY FOR A MACHINE: toward the human is free, the reverse needs a human.
# The direction is what makes that safe rather than a judgement about intent:
# tightening only ever REMOVES this side's permission and ADDS the human's
# sight of the pane, while relaxing GRANTS, and granting is the laundering
# move the send gate exists to refuse.
#
# THE BARE FORM IS CORRECT HERE because the section above removed the second
# window, so `alpha` holds exactly one agent. R9's refusal and the `--window`
# form are asserted at the end of this file, against a session that holds
# two, which is a precondition that section builds for itself rather than
# inheriting from here.
: >"$CAPLOG"
ATTN=agent run class alpha --attention human; unset ATTN
[ "$RC" = 0 ] || fail "escalating to the human was refused: rc=$RC $OUT"
eq "class-status" "$(jq 'd["status"]')" ok
eq "class-attention" "$(jq 'd["attention"]')" human
eq "class-control-untouched" "$(jq 'd["control"]')" None
case "$(cat "$CAPLOG")" in
*'@mux-attention human'*) ;;
*) fail "the escalation set nothing on the pane: $(cat "$CAPLOG")" ;;
esac
# AND IT LEFT `control` ALONE, which is the point of their being two markers:
# the supervisor keeps the write access it needs to go on nudging while the
# human is looking.
case "$(cat "$CAPLOG")" in
*'@mux-control'*) fail "changing attention also wrote control, so an
escalation silently revokes the supervisor's ability to type at the exact
moment it is handing over: $(cat "$CAPLOG")" ;;
esac

# AND IT IS LOGGED, which for the relax direction below IS the gate's value:
# the check is organisational, so the record of a change having happened is
# the part that survives somebody working around it.
grep -q 'alpha attention .* -> human via class' "$T/log" \
  || fail "the transition was not logged: $(cat "$T/log" 2>/dev/null)"

# --- RELAXING IS REFUSED WITHOUT A HUMAN ---------------------------------
# No tty here (the suite runs with stdin on a pipe), so this is the machine
# path, and it must refuse even though the caller asked plainly.
: >"$CAPLOG"
ATTN=human run class alpha --attention agent; unset ATTN
[ "$RC" = 1 ] || fail "relaxing must be refused with 1, got $RC: $OUT"
eq "relax-status" "$(jq 'd["status"]')" refused
eq "relax-reason" "$(jq 'd["reason"]')" relax
case "$(jq 'd["override"]')" in
*terminal*) ;;
*) fail "the refusal did not say what override exists, so a caller has to
guess: $OUT" ;;
esac
case "$(cat "$CAPLOG")" in
*set-option*) fail "it refused and wrote the option anyway: $(cat "$CAPLOG")" ;;
esac

# AND `--yes` ALONE IS NOT ENOUGH, which is the half that makes the flag mean
# anything: a flag is forgeable (the agent composes its own argv), so it
# grants nothing on its own. Same reasoning the send policy already uses.
: >"$CAPLOG"
ATTN=human run class alpha --attention agent --yes; unset ATTN
[ "$RC" = 1 ] || fail "--yes without a terminal must still refuse, got $RC"
case "$(cat "$CAPLOG")" in
*set-option*) fail "--yes alone was accepted: $(cat "$CAPLOG")" ;;
esac

# ... AND WITH BOTH, IT GOES THROUGH. Driven under a pty, because the gate is
# `[ -t 0 ]` and no piped test can enter that branch: without this the whole
# relax path would be asserted only by its refusals, which is the vacuous
# shape this suite keeps finding.
if [ "$T_PTY" = none ]; then
  printf 'note %s: no script(1), the relax-allowed path is unchecked\n' "$_name"
else
  : >"$CAPLOG"
  t_pty "$T/pty.log" "env -u TMUX -u MUX_SHARE MUX_DIR='$MUX_DIR' \
MUX_CACHE='$MUX_CACHE' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' \
PATH='$T/bin:$PATH' CAPLOG='$CAPLOG' ATTN=human MUX_LOG='$T/log' \
PANESFILE='$PANESFILE' \
'$HERE/bin/mux' agent class alpha --attention agent --yes" >/dev/null 2>&1
  case "$(cat "$CAPLOG")" in
  *'@mux-attention agent'*) ;;
  *) fail "with a terminal AND --yes the relax was still refused, so the
override exists in the message and nowhere else: $(cat "$CAPLOG")" ;;
  esac
fi

# --- A SESSION WITH NO TRACKED AGENT IS no-such-name --------------------
run class nosuch --attention human
[ "$RC" = 3 ] || fail "an unknown session must exit 3, got $RC: $OUT"

# --- AND IT REFUSES TO CROSS A PARTITION -------------------------------
# Reclassifying decides who may TYPE into a pane, so doing it across a
# boundary is the laundering move with an extra step.
run class wsess --partition work --attention human
[ "$RC" = 1 ] || fail "a cross-partition class must exit 1, got $RC: $OUT"
eq "class-cross" "$(jq 'd["reason"]')" cross-partition


# --- R9: WHICH WINDOW, AND WHY AN INDEX IS NOT AN ANSWER -------------------
# `alpha` holds two agent windows by now: @1 `main` (pane %1, blocked) and @9
# `worker` (pane %9, idle). That is the shape a supervisor actually runs in,
# and every assertion in this section is about mux refusing to guess inside
# it rather than answering a different question confidently.

# THE BARE FORM REFUSES. It used to take the session's WORST agent, so
# `class alpha --attention human` escalated whichever worker happened to be
# worst, and `read alpha` captured it. Both succeed at the wrong thing, which
# is this codebase's signature failure, so the answer is a refusal.
# THE PRECONDITION IS BUILT HERE, not inherited: the class section above
# deliberately removes this record, and a fixture that depends on what three
# sections up happened to leave behind is one that breaks for reasons that
# have nothing to do with it.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p9" idle %9 400 alpha x
python3 - "$XDG_RUNTIME_DIR/mux/agent-state/global/p9" <<'PY'
import sys
# agent_rec writes window 0, and this pane is alpha's SECOND window. The
# field has to be set because `peers` still enumerates windows from the
# RECORDS while the resolver reads them from live tmux, so a fixture that
# left it at 0 would make the two disagree about one session. That
# disagreement is also the argument for `window_id`: a record's index names
# a SLOT, and an id does not.
p = sys.argv[1]
f = open(p).read().split()
f[1] = "7"
open(p, "w").write(" ".join(f) + "\n")
PY
_read alpha
[ "$RC" = 1 ] || fail "the bare form must refuse with two agent windows,
got rc=$RC: $OUT"
eq r9-bare-status "$(jq 'd["status"]')" refused
eq r9-bare-count "$(jq '"2 agent windows" in d["message"]')" True
# AND IT CARRIES WHAT RESOLVES IT. A refusal naming the candidate ids is
# recoverable in one step; one that merely says "ambiguous" sends the caller
# back to `peers` to work out what mux already knew.
eq r9-bare-lists-ids "$(jq 'd["message"].count("@") >= 2')" True
eq r9-bare-names-flag "$(jq '"--window" in d["message"]')" True

# A NAME RESOLVES, and so does the id, to the SAME pane. The name is the
# convenience and the id is the handle; if they disagreed, one of them would
# be a second rule for the same question.
_read alpha --window worker
[ "$RC" = 0 ] || fail "--window by name was refused: $OUT"
eq r9-name-pane "$(jq 'd["pane"]')" %9
eq r9-name-wid "$(jq 'd["window"]')" @9
_read alpha --window @9
[ "$RC" = 0 ] || fail "--window by id was refused: $OUT"
eq r9-id-pane "$(jq 'd["pane"]')" %9
_read alpha --window main
eq r9-other-pane "$(jq 'd["pane"]')" %1

# AN UNKNOWN NAME REFUSES, which is the whole reason mux matches names itself
# instead of handing them to tmux: tmux's own name resolution FAILS OPEN.
# Measured 2026-10-04, `-t sess:nosuchname` resolves to a DIFFERENT window and
# exits 0, so a typo would read somebody else's screen and report success.
_read alpha --window nosuchwindow
[ "$RC" = 1 ] || fail "an unknown window NAME must refuse, got rc=$RC: $OUT"
eq r9-badname-status "$(jq 'd["status"]')" refused
eq r9-badname-quotes "$(jq '"nosuchwindow" in d["message"]')" True
# AND IT DID NOT CAPTURE ANYTHING, asserted separately because the refusal
# message and the absence of an answer are different bugs: a verb that
# refuses and answers anyway has told the caller two things.
eq r9-badname-no-text "$(jq '"text" not in d')" True

# AN UNKNOWN ID REFUSES TOO, and the message says the thing that makes an id
# trustworthy: it is never reused, so a stale one names NOTHING rather than
# whatever took the slot.
_read alpha --window @99
[ "$RC" = 1 ] || fail "an unknown window ID must refuse, got rc=$RC: $OUT"
eq r9-badid-status "$(jq 'd["status"]')" refused

# AN ID FROM ANOTHER SESSION REFUSES. A window id is server-global, so this
# is the one way an id can be precise and still wrong, and it is the case a
# caller reaches by pasting from a `peers --all`. @2 is bravo's.
_read alpha --window @2
[ "$RC" = 1 ] || fail "a foreign window id must refuse, got rc=$RC: $OUT"
eq r9-foreign-id "$(jq 'd["status"]')" refused
# The control: that same id DOES work for the session that owns it, so the
# refusal above is about membership and not about the id being unreadable.
_read bravo --window @2
[ "$RC" = 0 ] || fail "the owning session could not use its own id: $OUT"
eq r9-owner-id-pane "$(jq 'd["pane"]')" %2

# THE SEND GATE JUDGES THE PANE IT WILL TYPE INTO, not the session's worst.
# Those differ exactly when it matters: `main` is blocked and `worker` is
# idle, so a session-wide verdict would either lock the idle worker out or,
# worse, let a charge through to the blocked one with no acknowledgement.
pol 'send-blocked control:agent'
: >"$CAPLOG"
CLASS=agent run send alpha --window worker 'queued'; unset CLASS
[ "$RC" = 0 ] || fail "an idle worker was refused because a SIBLING window is
blocked, which is the session-wide verdict leaking into a per-window ask:
rc=$RC $OUT"
: >"$CAPLOG"
CLASS=agent run send alpha --window main 'queued'; unset CLASS
[ "$RC" = 1 ] || fail "a blocked pane accepted a charge with no
acknowledgement, got rc=$RC: $OUT"
eq r9-send-blocked "$(jq 'd["reason"]')" blocked
case "$(cat "$CAPLOG")" in
*send-keys*) fail "it refused and typed anyway: $(cat "$CAPLOG")" ;;
esac

# `peers` CARRIES BOTH, which is the answer side: a caller that cannot read
# the id cannot use the interface above.
run peers
eq r9-peers-wid \
  "$(jq 'sorted(p["window_id"] for p in d["peers"] \
if p["session"]=="alpha")')" "['@1', '@9']"
eq r9-peers-wname \
  "$(jq 'sorted(p["window_name"] for p in d["peers"] \
if p["session"]=="alpha")')" "['main', 'worker']"

# --- AN AMBIGUOUS NAME IS REFUSED, NOT RESOLVED ---------------------------
# ONLY ACT ON UNIQUENESS, rather than enforcing it: mux does not rename a
# window to keep names unique, because a caller that chose the name has to be
# able to re-derive it, and a suffix mux invented is not something it can
# know. So a duplicate is legal and merely unaddressable BY NAME.
printf 'alpha\t@11\tworker\t%%11\tglobal\n' >>"$PANESFILE"
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/pb" idle %11 400 alpha x
_read alpha --window worker
[ "$RC" = 1 ] || fail "a name matching two windows must refuse rather than
pick one, got rc=$RC: $OUT"
eq r9-ambig-status "$(jq 'd["status"]')" refused
eq r9-ambig-says-two "$(jq '"2 windows" in d["message"]')" True
# AND THE IDS ARE IN IT, which is what keeps an ambiguous name RECOVERABLE
# rather than a dead end: this is the one refusal whose remedy the caller
# cannot work out for itself.
eq r9-ambig-lists "$(jq 'all(w in d["message"] for w in ("@9", "@11"))')" True
# ... and the id still works, which is the recovery actually happening.
_read alpha --window @11
[ "$RC" = 0 ] || fail "the id did not resolve an ambiguously named window,
so the refusal above is a dead end: $OUT"
eq r9-ambig-recover "$(jq 'd["pane"]')" %11

pass
