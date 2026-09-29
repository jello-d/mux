#!/bin/sh
# test/mux-agent.t - `mux agent <verb>`, the MACHINE CONTRACT.
#
# What is asserted here is the contract itself, not the data: that every
# answer is a JSON document on STDOUT, that it carries a symbolic status, and
# that the status agrees with the exit code. The data is agent-state-summary's
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
_sock=
[ "${1:-}" = -L ] && _sock=$2
case " ${WATCHED:-} " in
*" $_sock "*) printf '/dev/pts/1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

RC=0
run() {   # <args...> -> stdout in $OUT, exit in $RC
	RC=0
	OUT=$(env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" \
		MUX_CACHE="$MUX_CACHE" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		PATH="$T/bin:$PATH" WATCHED="${WATCHED:-}" \
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

# --- ATTACHED BY DEFAULT, --any for everything ----------------------------
# A tray item means somebody is looking at it, and an agent asking what is
# going on wants the answer a human would see. `work` has state and no client.
WATCHED=global run status
eq default-hides-unwatched "$(jq 'len(d["partitions"])')" 1
WATCHED=global run status --any
eq any-shows-all "$(jq 'len(d["partitions"])')" 2

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
# state files -- and sourcing mux-sessions.sh without mux-paths.sh gave every
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
