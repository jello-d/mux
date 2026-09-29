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
# passes on a document no parser accepts -- which is precisely the failure the
# JSON emitter exists to prevent, so a test that could not see it would be
# asserting the wrong thing. python3 is the parser; without it this skips
# rather than pretending.
set -eu
_name=mux-agent
. "$(dirname "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || {
	printf 'skip %s (no python3 to parse with)\n' "$_name"; exit 0; }

XDG_RUNTIME_DIR=$T/run
MUX_DIR=$T/conf
MUX_CACHE=$T/cache
export XDG_RUNTIME_DIR MUX_DIR MUX_CACHE
mkdir -p "$XDG_RUNTIME_DIR/agent-state/global" \
	"$XDG_RUNTIME_DIR/agent-state/work" "$MUX_DIR/partitions" "$T/bin"

agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p1" blocked %1 100 alpha x
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p2" working %2 200 bravo x
agent_rec "$XDG_RUNTIME_DIR/agent-state/work/p1"   idle    %3 300 wsess x

# The same one-question tmux as mux-agent-summary.t: does partition X have a
# client attached? $WATCHED is the set that does.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
# ONE STUB, DEFINED ONCE. There were two definitions of this file for a while,
# the fuller one written further down -- so every assertion ABOVE it silently
# ran against a weaker tmux, and `peers` read a null class for a pane the test
# had just classified. A second definition of a fixture is a second tool, and
# which one a case gets depends on where it happens to sit.
#
# ONE ARM PER QUESTION. The client check used to run for EVERY call, and with
# $WATCHED empty its pattern `*" "*` matched `"  "` -- so a capture-pane call
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
*list-panes*)
	# One line per pane: id TAB class. $PANECLASS is "id=class,..." and
	# $NOSERVER makes the query FAIL, which is a different answer from an
	# empty one and the whole reason peers reports null rather than a
	# default.
	[ -z "${NOSERVER:-}" ] || exit 1
	printf '%%1\t%s\n%%2\t%s\n' "${CLASS1:-}" "${CLASS2:-}" ;;
*window_name*)   printf '%s\n' "${WINNAME:-main}" ;;
*@mux-control*)  printf '%s\n' "${CLASS:-}" ;;
*load-buffer*|*paste-buffer*|*send-keys*|*delete-buffer*)
	printf 'TMUX %s\n' "$*" >>"$CAPLOG" ;;
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
		NOSERVER="${NOSERVER:-}" \
		MUX_SEND_POLICY_FILE="$T/etc/send-policy" \
		"$HERE/bin/mux" agent "$@" 2>"$T/err") || RC=$?
}

# jq EXPR -- evaluate a python expression over the parsed document in $OUT.
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
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# `read` is a mux VERB here, not the shell builtin -- but shellcheck sees the
# word after a wrapper function and assumes the builtin, at every call site.
# One helper carries the suppression so a real `read` anywhere else in this
# file still fails, which is this project's rule for an intentional-but-rare
# exception.
# shellcheck disable=SC2162
_read() { run read "$@"; }

# --- the happy answer -----------------------------------------------------
WATCHED=global run status
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
# one sentence after calling a partition an isolation boundary -- so an agent
# in `work` reading `status` was told it was seeing its own partition while
# being handed `global`'s state and counts.
#
# The old assertion here encoded the bug: it asserted `--any` returned BOTH
# partitions, which was true only because nothing was scoping. A flag that
# parses and does nothing is worse than a missing one, because the caller
# believes it asked for something.
WATCHED=global run status --any
eq scoped-default "$(jq 'len(d["partitions"])')" 1
eq scoped-is-mine "$(jq 'd["partitions"][0]["partition"]')" global

# --all WIDENS, which is the direction the tray depends on: a reader on
# another box cannot know the partition names to ask for.
WATCHED=global run status --all --any
eq all-widens "$(jq 'len(d["partitions"])')" 2

# --partition SELECTS one that is not mine, and is the flag the skill
# documents and the verb did not parse at all.
WATCHED=global run status --partition work --any
eq part-selects "$(jq 'len(d["partitions"])')" 1
eq part-is-named "$(jq 'd["partitions"][0]["partition"]')" work
# `run` captures the status into $RC, so `$?` here reads the WRAPPER and is 0
# whatever the verb did -- the same shape as the vacuous assertions this suite
# has been bitten by before.
run status --partition
eq part-needs-a-name "$RC" 2
eq part-needs-a-name-says "$(jq 'd["status"]')" usage

# --- ATTACHED BY DEFAULT, --any for everything ----------------------------
# A tray item means somebody is looking at it, and an agent asking what is
# going on wants the answer a human would see. Asserted IN SCOPE, so it cannot
# be confused with the scoping above: the caller's own partition, with and
# without a client attached to it.
WATCHED=global run status
eq default-hides-unwatched "$(jq 'len(d["partitions"])')" 1
WATCHED= run status --any
eq any-shows-unattached "$(jq 'len(d["partitions"])')" 1

# --- NOTHING WATCHED IS AN EMPTY ARRAY, NOT AN ERROR ----------------------
# The JSON form of "empty is exit 0": a box where nobody is attached answers
# the same SHAPE as one with five partitions, so a consumer never has to tell
# a quiet answer from a broken one by looking at the exit code alone.
WATCHED= run status
eq empty-rc "$RC" 0
eq empty-ok "$(jq 'd["status"]')" ok
eq empty-arr "$(jq 'len(d["partitions"])')" 0

# --- peers: every session, and what it is doing ---------------------------
# The verb an agent reaches for first. HEADLESS by construction -- sessions
# come from the state FILES and roots from the session set -- so it answers
# over a transport, at boot, with no tmux client and no server attached.
# $MUX_STATE, which lib.sh already pins and exports for exactly this. Two
# wrong guesses first, and both failed the same silent way -- an empty root,
# no error -- which is why the assertion below is on the root and not merely
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
# state files -- and sourcing mux-sessions_lib without mux-paths_lib gave every
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
# billion -- no threshold to tune, and the two cannot be confused.
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p9" idle %9 "$(date +%s)" fresh x
printf 'fresh	/srv/fresh
' >>"$MUX_STATE/sessions.global"
run peers
eq peers-age-number "$(jq 'type(d["peers"][0]["age"]).__name__')" int
eq peers-age-sane "$(jq 'all(p["age"] >= 0 for p in d["peers"])')" True
# A record stamped in the FUTURE, which is what the clamp exists for: this
# host's clock moved, and "0" is the honest floor for "it began no earlier
# than now". Without a case for it the clamp is a guard nothing can kill.
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p8" idle %8 \
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
CLASS2=agent run peers
eq peers-class-default \
	"$(jq '[p["control"] for p in d["peers"] if p["session"]=="alpha"][0]')" \
	human
eq peers-class-agent \
	"$(jq '[p["control"] for p in d["peers"] if p["session"]=="bravo"][0]')" \
	agent

# NULL IS NOT `human`, and that distinction is the point. With no server
# reachable -- a remote `peers` at boot, which this verb is designed for --
# every pane would otherwise report as human-controlled: plausible, and wrong.
# peers still ANSWERS, because it derives its sessions from the state files.
NOSERVER=1 run peers
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
# is null rather than the default. `wsess` records pane %3, which the stub
# does not list.
CLASS2=agent run peers --partition work
eq peers-stale-pane \
	"$(jq '[p["control"] for p in d["peers"] if p["session"]=="wsess"][0]')" \
	None

# --- peers is scoped to ONE partition, and --all widens it ----------------
run peers
eq peers-n-after "$(jq 'len(d["peers"])')" 4
eq peers-scoped "$(jq 'set(p["partition"] for p in d["peers"])')" "{'global'}"
run peers --partition work
eq peers-other "$(jq 'set(p["partition"] for p in d["peers"])')" "{'work'}"
eq peers-other-n "$(jq 'len(d["peers"])')" 1
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
# -- the part only mux knows -- whether it is BLOCKED. Without this verb an
# orchestrator reaches around mux to `tmux send-keys`, re-derives pane
# resolution, and inherits none of the guards below.
mkdir -p "$T/etc"
seal_pol() { chmod 0444 "$T/etc/send-policy"; chmod 0555 "$T/etc"; }
# pol LINE -- replace the policy and seal it, which four cases below do.
pol() { unseal_pol; printf '%s\n' "$1" >"$T/etc/send-policy"; seal_pol; }
unseal_pol() { chmod 0755 "$T/etc" 2>/dev/null || true
	chmod 0644 "$T/etc/send-policy" 2>/dev/null || true; }
trap 'chmod 0755 "$T/etc" 2>/dev/null || true' EXIT INT TERM

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
# one, which is not where a partition's server lives -- so `send` read an
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
# `alpha` is blocked. With no class set the pane is a HUMAN's -- the safe
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
CLASS=agent run send alpha 'y' --answer-prompt
eq agent-nopol-rc "$RC" 1
eq agent-nopol-override "$(jq 'd["override"]')" none

# --- the policy grants the CLASS: now the capability is reported ----------
# A caller that does not know discovers it in one round trip and decides; one
# that does know passes the flag up front and pays nothing. That signal is why
# there is no standing always-open grant.
pol 'send-blocked control:agent'
CLASS=agent run send alpha 'y'
eq grant-rc "$RC" 1
eq grant-override "$(jq 'd["override"]')" available
eq grant-msg "$(jq '"--answer-prompt" in d["message"]')" True

# ... and WITH the acknowledgement it goes through.
: >"$CAPLOG"
CLASS=agent run send alpha 'y' --answer-prompt
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

# HYBRID IS ITS OWN CLASS and is NOT covered by an agent grant -- folding it
# into either neighbour was the wrong answer in both directions.
pol 'send-blocked control:agent'
CLASS=hybrid run send alpha 'y' --answer-prompt
eq hybrid-rc "$RC" 1
eq hybrid-override "$(jq 'd["override"]')" none
pol 'send-blocked control:hybrid'
CLASS=hybrid run send alpha 'y' --answer-prompt
eq hybrid-granted-rc "$RC" 0

# --- the two acknowledgements are SEPARATE --------------------------------
# Being allowed to answer prompts must never imply being allowed to type into
# a pane mux cannot classify.
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p7" weirdstate %7 100 odd x
printf 'odd\t/srv/odd\n' >>"$MUX_STATE/sessions.global"
pol 'send-blocked control:agent'
CLASS=agent run send odd 'x' --answer-prompt
eq unk-rc "$RC" 1
eq unk-reason "$(jq 'd["reason"]')" unknown
eq unk-override "$(jq 'd["override"]')" none
# ... and with the `unknown` grant in force, the ACKNOWLEDGEMENT is still
# required. Asserted separately from the grant, or the policy check covers for
# the ack check and neither is individually killable -- which is exactly what
# mutation reported here.
pol 'send-unknown control:agent'
CLASS=agent run send odd 'x'
eq unk-noack-rc "$RC" 1
eq unk-noack-override "$(jq 'd["override"]')" available
eq unk-noack-msg "$(jq '"--blind" in d["message"]')" True
CLASS=agent run send odd 'x' --blind
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
# Several statuses may share a code -- that is why both exist -- but a status
# must not be able to mean two different exits, or a reader that switches on
# one will disagree with a shell that switches on the other.
for _case in 'nosuchverb usage 2' 'status ok 0'; do
	# shellcheck disable=SC2086   # three words per entry, split on purpose
	set -- $_case
	WATCHED=global run "$1"
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
	WATCHED=global run $_args
	case $RC in
	0|1|2|3) ;;
	*) fail "\`mux agent $_args\` exited $RC, outside mux's four codes --
126, 127 and 255 must stay attributable to the shell and to ssh" ;;
	esac
done

pass
