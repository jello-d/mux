#!/bin/sh
# test/mux-latch.t - the latch STATE MACHINE, driven entirely through its seams.
#
# The whole design rests on one asymmetry: retrying is correct in every state
# except `blocked`, where each attempt is a credential prompt and a loop is the
# prompt storm. So the assertions that matter are about what latch REFUSES to
# do:
#
#   it must not attempt while blocked          (that is the storm)
#   it must not retry after the human quit     (resurrects what they closed)
#   it must not read "cannot tell" as usable   (the HOOK_NA rule)
#
# Every seam is a command, so all of it is stubbed: no ssh, no network and no
# sleeping. A stub transport is fed a scripted sequence of exits and stderr, and
# the status seam records the state sequence, which is what gets asserted.
set -eu
_name=mux-latch
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf"
STATES=$T/states        # the status seam's log: one state per line
TRIES=$T/tries          # one line per transport invocation
AUTHLOG=$T/authlog      # one line per auth question
SCRIPT=$T/script        # the transport's scripted answers: "<exit> <stderr>"
export STATES TRIES AUTHLOG SCRIPT

cat >"$T/bin/status" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$STATES"
EOF
# The transport pops one line off the script per call. Running past the end is
# an error rather than a silent repeat, so a test cannot accidentally assert
# against an infinite loop it did not intend.
cat >"$T/bin/transport" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TRIES"
_l=$(head -1 "$SCRIPT" 2>/dev/null || true)
[ -n "$_l" ] || { echo "transport: script exhausted" >&2; exit 99; }
tail -n +2 "$SCRIPT" 2>/dev/null >"$SCRIPT.t" || :
mv -f "$SCRIPT.t" "$SCRIPT"
_rc=${_l%% *}; _msg=${_l#* }
[ "$_msg" = "$_l" ] && _msg=
[ -n "$_msg" ] && printf '%s\n' "$_msg" >&2
exit "$_rc"
EOF
# The auth stub answers from a file, so a run can watch a credential appear.
cat >"$T/bin/auth" <<'EOF'
#!/bin/sh
printf 'asked\n' >>"$AUTHLOG"
exit "$(cat "$T_AUTH" 2>/dev/null || echo 0)"
EOF
cat >"$T/bin/probe" <<'EOF'
#!/bin/sh
exit "$(cat "$T_PROBE" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/status" "$T/bin/transport" "$T/bin/auth" "$T/bin/probe"
T_AUTH=$T/authrc; T_PROBE=$T/probrc; export T_AUTH T_PROBE
printf '0\n' >"$T_AUTH"; printf '0\n' >"$T_PROBE"

# No real sleeping: the backoff is exercised, not waited for.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/nosleep"; chmod +x "$T/bin/nosleep"

latch() {
	: >"$STATES"; : >"$TRIES"; : >"$AUTHLOG"
	_lr=0
	env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" \
		MUX_SHARE="$HERE/share" \
		T_AUTH="$T_AUTH" T_PROBE="$T_PROBE" \
		STATES="$STATES" TRIES="$TRIES" AUTHLOG="$AUTHLOG" \
		SCRIPT="$SCRIPT" \
		MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
		MUX_LATCH_AUTH="$T/bin/auth" \
		MUX_LATCH_PROBE="$T/bin/probe" \
		MUX_LATCH_STATUS="$T/bin/status" \
		MUX_LATCH_SLEEP="$T/bin/nosleep" \
		MUX_LATCH_BACKOFF=1 MUX_LATCH_BLOCKED_WAIT=1 \
		MUX_LATCH_MAX_TRIES="${MAXT:-6}" \
		"$HERE/libexec/mux-latch" "$@" >/dev/null 2>&1 || _lr=$?
	echo "$_lr"
}
seq_of()  { tr '\n' ' ' <"$STATES"; }
n_tries() { grep -c . "$TRIES" 2>/dev/null || true; }
n_auth()  { grep -c . "$AUTHLOG" 2>/dev/null || true; }

# --- the human quits: terminal, exit 0, and NO retry --------------------
# Retrying here would resurrect a session they just closed. This is the case
# autossh gets wrong by design.
printf '0\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 0 ] || fail "a deliberate quit should exit 0, got $_rc"
[ "$(n_tries)" = 1 ] || fail "a quit was retried $(n_tries) times"
case "$(seq_of)" in
*ended*) ;;
*) fail "the quit was not reported as ended: [$(seq_of)]" ;;
esac

# --- the transport drops: that IS retried -------------------------------
_drop='255 ssh: connect to host box port 22: Connection timed out'
printf '%s\n%s\n0\n' "$_drop" "$_drop" >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 0 ] || fail "a recovered drop should end 0, got $_rc"
[ "$(n_tries)" = 3 ] \
	|| fail "expected 3 attempts across two drops, got $(n_tries)"
case "$(seq_of)" in
*probing*ended*) ;;
*) fail "a drop should report probing then ended: [$(seq_of)]" ;;
esac

# --- A REJECTED CREDENTIAL IS TERMINAL, NOT RETRIED --------------------
# The load-bearing assertion, and the one that separated `denied` from
# `blocked`. Here the credential IS live, so pre-flight passes and the attempt
# happens -- and the far side refuses it. latch cannot observe a human fixing
# authorized_keys, so there is no condition on which to retry: looping would be
# the prompt storm wearing a backoff.
printf '255 jello@box: Permission denied (publickey,password).\n' >"$SCRIPT"
printf '0\n' >"$T_AUTH"                      # a credential IS live
_rc=$(MAXT=5 latch box:proj)
[ "$_rc" = 1 ] || fail "a rejected credential should exit non-zero, got $_rc"
[ "$(n_tries)" = 1 ] \
	|| fail "latch offered a rejected credential $(n_tries) times; that is the
storm this design exists to prevent, and a backoff does not make it not one"
case "$(seq_of)" in
*denied*) ;;
*) fail "a rejected credential was not reported as denied: [$(seq_of)]" ;;
esac

# --- A HOST KEY REFUSAL IS ALSO TERMINAL ------------------------------
# Same family as a rejected credential, pointing the other way: we refused THEM.
# ssh exits 255 and its message says nothing about "denied", so this classified
# as retryable and latch would have spun forever on a problem only a human can
# fix. Found in a live run against a rebuilt host, not by this suite.
printf '255 Host key verification failed.\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "a host key refusal should exit non-zero, got $_rc"
[ "$(n_tries)" = 1 ] \
	|| fail "a host key refusal was retried $(n_tries) times; no amount of
patience fixes a changed host key"
case "$(seq_of)" in
*denied*) ;;
*) fail "a host key refusal should report denied: [$(seq_of)]" ;;
esac

# --- THE REPORT IS NOT TRUNCATED --------------------------------------
# _say's detail is wrapped across source lines to stay inside 80 columns, and
# with `"$2"` alone everything after the first fragment was dropped: it printed
# "this needs a human: latch cannot see when a" and stopped mid-sentence.
# The state was right and the explanation was unreadable, which is the half a
# human actually uses.
printf '255 Host key verification failed.\n' >"$SCRIPT"
_err=$T/said
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" \
	MUX_SHARE="$HERE/share" \
	T_AUTH="$T_AUTH" T_PROBE="$T_PROBE" STATES="$STATES" \
	TRIES="$TRIES" AUTHLOG="$AUTHLOG" SCRIPT="$SCRIPT" \
	MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
	MUX_LATCH_AUTH="$T/bin/auth" MUX_LATCH_PROBE="$T/bin/probe" \
	MUX_LATCH_SLEEP="$T/bin/nosleep" MUX_LATCH_MAX_TRIES=3 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>"$_err" || true
grep -q 'retrying a refusal forever' "$_err" \
	|| fail "the denied explanation was cut off; a wrapped _say call must
still print whole. Got:
$(cat "$_err")"

# --- pre-flight blocked WAITS, and leaves by itself when a key appears --
# This is what makes blocked a waiting state rather than a dead end: no prompt
# while it waits, and no human babysitting to get it moving again.
printf '1\n' >"$T_AUTH"
cat >"$T/bin/auth" <<'EOF'
#!/bin/sh
printf 'asked\n' >>"$AUTHLOG"
# Blocked for the first two questions, then a key appears.
if [ "$(grep -c . "$AUTHLOG")" -lt 3 ]; then exit 1; fi
exit 0
EOF
chmod +x "$T/bin/auth"
printf '0\n' >"$SCRIPT"
_rc=$(MAXT=8 latch box:proj)
[ "$_rc" = 0 ] || fail "latch never recovered after the credential appeared"
[ "$(n_tries)" = 1 ] || fail "it attempted before the credential was live"
case "$(seq_of)" in
*blocked*probing*ended*) ;;
*) fail "expected blocked then probing then ended: [$(seq_of)]" ;;
esac
# restore the file-driven auth stub
cat >"$T/bin/auth" <<'EOF'
#!/bin/sh
printf 'asked\n' >>"$AUTHLOG"
exit "$(cat "$T_AUTH" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/auth"
printf '0\n' >"$T_AUTH"

# --- a pre-flight block never attempts at all --------------------------
# The storm is avoided by CONSTRUCTION, not damped: with no live credential,
# latch does not make the attempt that would raise the prompt.
printf '1\n' >"$T_AUTH"
: >"$SCRIPT"
MAXT=3 latch box:proj >/dev/null
[ "$(n_tries)" = 0 ] \
	|| fail "latch attempted $(n_tries) times without a live credential"
printf '0\n' >"$T_AUTH"

# --- "cannot tell" is never read as usable -----------------------------
# The HOOK_NA rule. A probe exiting 78 has not answered, so latch must wait
# rather than attempt, and must not report the target as reachable.
printf '78\n' >"$T_PROBE"
: >"$SCRIPT"
MAXT=3 latch box:proj >/dev/null
[ "$(n_tries)" = 0 ] \
	|| fail "a probe that could not answer was treated as usable"
case "$(seq_of)" in
*unknown*) ;;
*) fail "an unanswerable probe should report unknown: [$(seq_of)]" ;;
esac
# ... and an unrecognised hook exit is also "cannot tell", not a verdict.
printf '42\n' >"$T_PROBE"
: >"$SCRIPT"
MAXT=3 latch box:proj >/dev/null
[ "$(n_tries)" = 0 ] || fail "an unexpected probe exit was treated as usable"
printf '0\n' >"$T_PROBE"

# --- NO PROBE CONFIGURED MEANS PROCEED, not wait -----------------------
# The default configuration has no probe seam, and `_ask ""` answers 2 for it,
# the same code a probe that RAN and could not tell returns. Those are opposite
# instructions: proceed versus wait. Conflating them made a stock `mux latch`
# sit in `unknown` and never attach once, which a smoke test caught and this
# suite did not, because every other case here configures a probe.
_saveprobe=$T/bin/probe
printf '0\n' >"$SCRIPT"
: >"$STATES"; : >"$TRIES"
_lr=0
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" \
	MUX_SHARE="$HERE/share" \
	STATES="$STATES" TRIES="$TRIES" SCRIPT="$SCRIPT" \
	MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
	MUX_LATCH_AUTH=/bin/true \
	MUX_LATCH_STATUS="$T/bin/status" \
	MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=3 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || _lr=$?
[ "$_lr" = 0 ] || fail "with no probe configured latch should just attempt and
report the session ending; got exit $_lr and states [$(seq_of)]"
[ "$(n_tries)" = 1 ] \
	|| fail "with no probe configured latch attempted $(n_tries) times;
no probe means no opinion, so the attempt itself is the probe"

# --- an unusable target is retried, not escalated ----------------------
printf '1\n' >"$T_PROBE"
: >"$SCRIPT"
MAXT=3 latch box:proj >/dev/null
[ "$(n_tries)" = 0 ] || fail "latch attempted against an unusable target"
case "$(seq_of)" in
*probing*) ;;
*) fail "an unusable target should stay probing: [$(seq_of)]" ;;
esac
printf '0\n' >"$T_PROBE"

# --- the far side lost the session: reported, never recreated ---------
# Exit 3 is mux's unknown-name code, and since 0.35 it is the only signal the
# classifier consults for this.
printf '3 mux: no such session: proj\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "a vanished session should exit non-zero, got $_rc"
[ "$(n_tries)" = 1 ] || fail "a vanished session was retried"
case "$(seq_of)" in
*gone*) ;;
*) fail "a vanished session was not reported as gone: [$(seq_of)]" ;;
esac

# --- EXIT 3 IS THE UNKNOWN-NAME CODE, AND IT BEATS THE STRING --------
# mux returns 3 for "the name is not known here", from any verb. That is what
# lets the classifier decide on a NUMBER rather than grepping stderr for "no
# such session" -- which made the wording of a message on one machine
# load-bearing for a decision on another, and needed a test to hold the
# sentence still.
#
# There is NO string fallback. Two mechanisms for one fact is two things to
# test and two ways to drift, so a remote older than the code reports `refused`
# with its own message -- worse, but not silent, and the fix is to upgrade it.
printf '3\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "an unknown name should exit non-zero, got $_rc"
case "$(seq_of)" in
*gone*) ;;
*) fail "exit 3 from the far side is mux's unknown-name code and must be read
as gone, with no reference to the message: [$(seq_of)]" ;;
esac
[ "$(n_tries)" = 1 ] || fail "an unknown name was retried $(n_tries) times"

# ... and the phrase alone is NOT enough any more. This is the assertion that
# keeps the compatibility path from creeping back in: if someone re-adds the
# grep, this goes red.
printf '1 mux: no such session: proj\n' >"$SCRIPT"
_rc=$(latch box:proj)
case "$(seq_of)" in
*"latch: gone"*) fail "exit 1 with the old phrase must NOT be read as gone.
The code is the contract; re-adding the string match gives one fact two
mechanisms, which is two things to test and two ways to drift:
[$(seq_of)]" ;;
esac
case "$(seq_of)" in
*refused*) ;;
*) fail "a pre-0.35 remote should still report refused, and still print what
the far side said: [$(seq_of)]" ;;
esac

# --- THE TMUX SERVER WENT AWAY UNDER THE ATTACH ----------------------
# The one exit 1 latch cannot read. tmux writes "lost server" to the TERMINAL,
# not to stderr, so all latch sees is the transport's generic goodbye
# ("Connection to host closed.") -- indistinguishable from any other exit 1, and
# reported as a bare `refused` that told the operator nothing.
#
# So latch ASKS, with one read-only query, and only on this already-terminal
# path. Any answer from mux (even exit 2 from one too old to know the verb)
# proves the far side is up, which means the failure was about the SESSION.
ASKED=$T/asked; export ASKED
cat >"$T/bin/ambig" <<'EOF'
#!/bin/sh
for _a in "$@"; do :; done
case "$_a" in
*capabilities*)
	printf 'q\n' >>"$ASKED"
	[ -n "${ALIVE:-}" ] && exit "${ALIVERC:-0}"
	echo 'ssh: connect to host box port 22: No route to host' >&2
	exit 255 ;;
esac
printf '%s\n' "${MSG:-Connection to box closed.}" >&2
exit "${XRC:-1}"
EOF
chmod +x "$T/bin/ambig"

# Every caller needs `|| true`: latch exits 1 on all of these (they are terminal
# states, correctly), and under `set -e` a failing command substitution takes
# the whole test file down SILENTLY -- exit 1, no message, nothing to read.
amb() {   # -> stderr of a run with the given env
	: >"$ASKED"
	# INTENTIONAL and in this order: `2>&1 >/dev/null` points stderr at the
	# capture and THEN sends stdout to /dev/null, which yields stderr alone.
	# Reversing it would capture both. latch reports on stderr, so stderr is
	# the whole subject here.
	# shellcheck disable=SC2069
	env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
		ASKED="$ASKED" ALIVE="${A_ALIVE:-}" ALIVERC="${A_ALIVERC:-0}" \
		MSG="${A_MSG:-}" XRC="${A_XRC:-1}" \
		MUX_LATCH_TRANSPORT="$T/bin/ambig %h sh -lc %c" \
		MUX_LATCH_AUTH=/bin/true MUX_LATCH_RESTORE=/bin/true \
		MUX_LATCH_SLEEP="$T/bin/nosleep" MUX_LATCH_MAX_TRIES=1 \
		"$HERE/libexec/mux-latch" box:k 2>&1 >/dev/null
}

# THE FAR SIDE'S OWN MESSAGE IS NEVER REPLACED BY A GUESS. This is the
# regression that mattered: an earlier version reported `gone -- its tmux server
# went away` whenever stderr carried no `mux:` prefix, and tmux's own messages
# carry none. A `mux resume` that could not attach said "open terminal failed:
# not a terminal" -- the entire answer -- and latch threw it away to make a
# confident claim about a host with five healthy sessions.
_o=$(A_ALIVE=1 A_MSG='open terminal failed: not a terminal' amb || true)
case "$_o" in
*"open terminal failed"*) ;;
*) fail "the far side's own message must be reported, not replaced by a guess
at the cause. Got:
$_o" ;;
esac
case "$_o" in
*"went away"*|*"not running any more"*) fail "latch named a cause it cannot
see. 'the far side is up' is all the liveness query establishes; the session
may be fine and the attach may have failed for its own reasons. Got:
$_o" ;;
esac
# `gone` is reserved for exit 3, which is definitive. An exit 1 is a refusal.
case "$_o" in
*"latch: gone"*) fail "an exit 1 must not report gone: nothing here shows the
session is gone. Got:
$_o" ;;
esac
# The query still earns its place, because "the far side is up" is ESTABLISHED
# rather than inferred, and it rules out the network.
case "$_o" in
*"not the connection"*) ;;
*) fail "when the far side answers, say so: it rules out the network, which is
the one thing latch can actually establish here. Got:
$_o" ;;
esac
[ "$(grep -c . "$ASKED")" = 1 ] \
	|| fail "expected exactly one liveness query, got $(grep -c . "$ASKED")"

# An old remote answers the query with exit 2 and usage. That is still an
# ANSWER, and still proves the far side is up.
_o=$(A_ALIVE=1 A_ALIVERC=2 amb || true)
case "$_o" in
*"not the connection"*) ;;
*) fail "exit 2 from a remote too old for 'mux capabilities' still proves it is
alive, so the verdict must be the same. Got:
$_o" ;;
esac

# Far side NOT answering: say the connection went too, and claim nothing about
# a session that cannot be seen at all.
_o=$(amb || true)
case "$_o" in
*"latch: gone"*) fail "with the far side unreachable latch cannot know the
session is gone, and must not claim it. Got:
$_o" ;;
esac
case "$_o" in
*"not answering"*) ;;
*) fail "when the follow-up query also fails, the report must say the
connection went too. Got:
$_o" ;;
esac

# --- AND THE QUERY IS ONLY FOR THE AMBIGUOUS CASE --------------------
# An exit 1 that DOES carry a mux message needs no second round trip: the far
# side already said why. Asking anyway would cost a connection on every
# ordinary refusal.
_o=$(A_ALIVE=1 A_MSG='mux: it went wrong somehow' amb || true)
case "$_o" in
*"latch: refused"*) ;;
*) fail "an exit 1 with the far side's own explanation is a refusal, and the
explanation is what gets reported: [$_o]" ;;
esac
case "$_o" in
*"went wrong somehow"*) ;;
*) fail "the far side's own message must reach the operator: [$_o]" ;;
esac
[ "$(grep -c . "$ASKED")" = 0 ] \
	|| fail "latch made a liveness query for an exit 1 that already carried a
mux message. The query exists for the case mux said nothing about."

# An unknown name is exit 3 now, and needs no query either -- the CODE is
# conclusive, which is the whole reason it replaced the phrase.
_o=$(A_ALIVE=1 A_XRC=3 A_MSG='mux: no such session: k' amb || true)
case "$_o" in
*"latch: gone"*) ;;
*) fail "exit 3 is conclusive on its own: [$_o]" ;;
esac
[ "$(grep -c . "$ASKED")" = 0 ] \
	|| fail "latch queried after an exit 3, which is already the answer"

# Same for a remote too old for the VERB (exit 2 + usage): it explained itself.
_o=$(A_ALIVE=1 A_XRC=2 A_MSG='mux: unknown verb: go' amb || true)
case "$_o" in
*"latch: refused"*) ;;
*) fail "an exit 2 from the far side is a version answer: [$_o]" ;;
esac
[ "$(grep -c . "$ASKED")" = 0 ] \
	|| fail "latch queried after an exit 2, which already explained itself"

# --- the remote mux is too old for the verb ---------------------------
# exit 2 from the far side is a VERSION answer, not a transport failure, so
# retrying cannot help and latch stops.
printf '2 mux: unknown verb: go\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "an unknown remote verb should exit non-zero, got $_rc"
[ "$(n_tries)" = 1 ] \
	|| fail "an unknown remote verb was retried $(n_tries) times"
case "$(seq_of)" in
*refused*) ;;
*) fail "a too-old remote should report refused: [$(seq_of)]" ;;
esac

# --- the target parses, and a missing one is a usage error -----------
printf '0\n' >"$SCRIPT"
latch box:proj >/dev/null
grep -q 'box proj' "$TRIES" || fail "host and session were not substituted:
[$(cat "$TRIES")]"
printf '0\n' >"$SCRIPT"
latch box >/dev/null
grep -q 'box box' "$TRIES" \
	|| fail "with no session the host should be used: [$(cat "$TRIES")]"
_rc=$(latch)
[ "$_rc" = 2 ] || fail "no target is a usage error (exit 2), got $_rc"

# --- %c ARRIVES AS ONE ARGV ELEMENT ----------------------------------
# The whole reason the transport stopped being a string. The default template is
# `ssh -t %h sh -lc %q`, and if the command splits, the inner shell gets `mux`
# as its -c string with `go` as $0 -- which silently runs the bare session
# PICKER instead of the session you asked for. Measured against a real ssh
# before it was believed.
#
# The stub reports $# and its last argument, so a split is visible as a COUNT
# rather than as a downstream symptom.
cat >"$T/bin/argv" <<'EOF'
#!/bin/sh
# POSIX has no ${!#}, so walk to the last argument. The COUNT is the assertion;
# the last element is what makes a split legible when it fails.
_a=
for _a in "$@"; do :; done
printf 'n=%s last=[%s]\n' "$#" "$_a" >"$TRIES.argv"
exit 0
EOF
chmod +x "$T/bin/argv"
: >"$TRIES"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	TRIES="$TRIES" \
	MUX_LATCH_TRANSPORT="$T/bin/argv -t %h sh -lc %c" \
	MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_MAX_TRIES=1 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
_got=$(cat "$TRIES.argv" 2>/dev/null || true)
[ "$_got" = 'n=5 last=[mux go proj]' ] \
	|| fail "%c must arrive as ONE argv element. Wanted
  n=5 last=[mux go proj]
got
  $_got
A count above 5 means the command word-split, and the far side would run a
different command from the one latch composed."

# %q is the same element, shell-quoted for the REMOTE shell, because ssh
# concatenates its arguments and the far side re-parses them.
: >"$TRIES"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	TRIES="$TRIES" \
	MUX_LATCH_TRANSPORT="$T/bin/argv -t %h sh -lc %q" \
	MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_MAX_TRIES=1 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
_got=$(cat "$TRIES.argv" 2>/dev/null || true)
[ "$_got" = "n=5 last=['mux go proj']" ] \
	|| fail "%q must be one element AND quoted for the remote shell. Wanted
  n=5 last=['mux go proj']
got
  $_got"

# --- A NAMED HOOK THAT DOES NOT EXIST FAILS LOUDLY -------------------
# Silently carrying on means the classifier never answers, every attempt lands
# in `unknown`, and latch retries forever against a host that is perfectly fine.
# That is what a stale MUX_SHARE produced during development, with nothing on
# screen to say why.
_err=$T/hookerr
_rc=0
# BOUNDED, because the assertion is that it exits 2 BEFORE doing anything. If
# the guard is ever removed, latch falls through into the retry loop, and with
# the defaults that is forever with real sleeps -- which hangs the runner
# instead of failing it. A test whose failure mode is a hang teaches nothing.
printf '0\n' >"$SCRIPT"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	SCRIPT="$SCRIPT" TRIES="$TRIES" \
	MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
	MUX_LATCH_CLASSIFY=no-such-hook-anywhere \
	MUX_LATCH_SLEEP="$T/bin/nosleep" MUX_LATCH_MAX_TRIES=2 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>"$_err" || _rc=$?
[ "$_rc" = 2 ] \
	|| fail "a named hook that does not resolve is a config error (exit 2),
got $_rc"
grep -q 'no-such-hook-anywhere' "$_err" \
	|| fail "the failure must name the hook it could not find, got:
$(cat "$_err")"
# An EMPTY seam is the opposite and must stay silent: nobody asked for a hook.
printf '0\n' >"$SCRIPT"
_rc=$(MUX_LATCH_PROBE= latch box:proj)
[ "$_rc" = 0 ] \
	|| fail "an unset seam is not a missing hook and must not fail, got $_rc"

# --- THE SHIPPED HOOKS ARE FOUND BY BARE NAME ------------------------
# The library only works if a name resolves, and the overlay must win over the
# shipped set the same way layouts and themes do.
mkdir -p "$T/conf/latch"
cat >"$T/conf/latch/ssh-classify" <<'EOF'
#!/bin/sh
printf 'gone'
EOF
chmod +x "$T/conf/latch/ssh-classify"
printf '255 whatever\n' >"$SCRIPT"
_rc=$(latch box:proj)
case "$(seq_of)" in
*gone*) ;;
*) fail "an overlay hook must win over the shipped one of the same name:
[$(seq_of)]" ;;
esac
rm -rf "$T/conf/latch"

# --- THE TERMINAL IS PUT BACK FIRST, BEFORE ANYTHING IS REPORTED -----
# tmux dying with ssh never sends its teardown, so the terminal is left in
# tmux's mode: cursor hidden, mouse reporting on, alternate screen up.
#
# ORDER IS THE ASSERTION, not merely that it happens. The human is sitting in
# front of a wedged terminal right now, and latch's own messages go to that same
# terminal -- printing "probing, retrying in 8s" into a hidden-cursor alternate
# screen is how a reconnect looks like a hang. Repairing after the report, or
# after the backoff, would be most of the bug still present.
ORDER=$T/order; export ORDER
cat >"$T/bin/restore" <<'EOF'
#!/bin/sh
printf 'restore\n' >>"$ORDER"
EOF
cat >"$T/bin/orderstatus" <<'EOF'
#!/bin/sh
printf 'report:%s\n' "$1" >>"$ORDER"
EOF
chmod +x "$T/bin/restore" "$T/bin/orderstatus"

_drop='255 ssh: connect to host box port 22: Connection timed out'
printf '%s\n0\n' "$_drop" >"$SCRIPT"
: >"$ORDER"; : >"$TRIES"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	ORDER="$ORDER" SCRIPT="$SCRIPT" TRIES="$TRIES" \
	MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
	MUX_LATCH_AUTH=/bin/true \
	MUX_LATCH_RESTORE="$T/bin/restore" \
	MUX_LATCH_STATUS="$T/bin/orderstatus" \
	MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=3 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true

# The first thing after a drop must be the repair, and the report after it.
_seq=$(tr '\n' ' ' <"$ORDER")
case "$_seq" in
"report:attaching restore "*) ;;
*) fail "the terminal repair must come FIRST after the transport returns, and
before any report. Sequence was: [$_seq]" ;;
esac
# ... and specifically before the state report that follows the drop.
_first_state=$(grep -n 'report:probing' "$ORDER" | head -1 | cut -d: -f1)
_first_rest=$(grep -n 'restore' "$ORDER" | head -1 | cut -d: -f1)
[ -n "$_first_rest" ] || fail "the restore seam was never called"
[ -n "$_first_state" ] \
	&& [ "$_first_rest" -lt "$_first_state" ] \
	|| fail "the repair ran AFTER the drop was reported. The message goes to
the same wedged terminal, so this is the ordering that decides whether the
human can read it. Sequence: [$_seq]"

# It runs on a CLEAN end too. A tidy quit usually tears down properly, but
# `usually` is not a thing to depend on, and the repair is idempotent.
printf '0\n' >"$SCRIPT"
: >"$ORDER"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	ORDER="$ORDER" SCRIPT="$SCRIPT" TRIES="$TRIES" \
	MUX_LATCH_TRANSPORT="$T/bin/transport %h %s" \
	MUX_LATCH_AUTH=/bin/true \
	MUX_LATCH_RESTORE="$T/bin/restore" \
	MUX_LATCH_SLEEP="$T/bin/nosleep" MUX_LATCH_MAX_TRIES=1 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
grep -q restore "$ORDER" \
	|| fail "the terminal repair was skipped on a clean end. A quit through a
dying connection leaves the same wreckage, and the repair is idempotent."

# --- NO SESSION NAMED MEANS `mux resume`, NOT A GUESSED NAME ---------
# `mux latch manifestor` used to send `mux go manifestor`, using the HOSTNAME as
# a session name. It succeeds, hands you a session that is not yours, and on
# retry asks attach-only for a name that never existed and reports `gone`. A
# wrong answer wearing the shape of a right one, and the reason this asserts the
# exact command rather than just "it attached".
#
# resume is correct BECAUSE of how it creates: it rebuilds what that box
# actually had, which is the rebooted-host case handled properly.
cat >"$T/bin/echocmd" <<'EOF'
#!/bin/sh
for _a in "$@"; do :; done
printf '%s\n' "$_a" >>"$CMDS"
exit 0
EOF
chmod +x "$T/bin/echocmd"
CMDS=$T/cmds; export CMDS

sent() {   # <target> -> the remote command latch composed
	: >"$CMDS"
	env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
		CMDS="$CMDS" \
		MUX_LATCH_TRANSPORT="$T/bin/echocmd %h sh -lc %c" \
		MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
		MUX_LATCH_MAX_TRIES=1 \
		"$HERE/libexec/mux-latch" "$1" >/dev/null 2>&1 || true
	head -1 "$CMDS"
}

[ "$(sent box)" = 'mux resume' ] \
	|| fail "with no session named, latch must send 'mux resume', got
[$(sent box)]. Sending a go at the HOSTNAME attaches a session that is not
yours and looks like it worked."
[ "$(sent box:)" = 'mux resume' ] \
	|| fail "a trailing colon names no session either, got [$(sent box:)]"
[ "$(sent box:proj)" = 'mux go proj' ] \
	|| fail "a named session must be a plain go, got [$(sent box:proj)]"
# A name containing a colon belongs to the SESSION: the host is the first field
# only, so everything after the first colon is the name.
[ "$(sent box:a:b)" = 'mux go a:b' ] \
	|| fail "only the FIRST colon splits host from session, got
[$(sent box:a:b)]"

# --- ATTACH-ONLY IS NEGOTIATED, NOT ASSUMED --------------------------
# The first attempt may CREATE (you asked to latch onto something). Every
# attempt after it must ask for --attach-only, so a rebooted host is reported
# rather than silently replaced by an empty session.
#
# But only if the far side HAS it. A remote too old answers exit 2 with a usage
# block, so using the flag blind would make latch work perfectly until the first
# drop and then break -- the exact discover-by-failure the capability handshake
# exists to end. Verified live against manifold on 0.30, which declares
# `attach-only no` and must therefore keep getting the creating form.
cat >"$T/bin/negotiate" <<'EOF'
#!/bin/sh
# Records every remote command, and answers `capabilities` per CAPRC/CAPOUT.
for _a in "$@"; do :; done
printf '%s
' "$_a" >>"$CMDLOG"
case "$_a" in
*capabilities*)
	[ -n "${CAPOUT:-}" ] && printf '%s
' "$CAPOUT"
	exit "${CAPRC:-0}" ;;
esac
# Drop retryably for the first $DROPS attaches (default 1), so the attempt
# AFTER a retry is the one under test.
printf 'x\n' >>"$ONCE"
if [ "$(grep -c . "$ONCE")" -le "${DROPS:-1}" ]; then
	echo 'ssh: connect to host box port 22: Connection timed out' >&2
	exit 255
fi
exit 0
EOF
chmod +x "$T/bin/negotiate"
CMDLOG=$T/cmdlog; ONCE=$T/once; export CMDLOG ONCE

neg() {   # CAPRC CAPOUT -> the command used on the SECOND attempt
	: >"$CMDLOG"; rm -f "$ONCE"
	env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
		CMDLOG="$CMDLOG" ONCE="$ONCE" CAPRC="$1" CAPOUT="$2" \
		MUX_LATCH_TRANSPORT="$T/bin/negotiate %h sh -lc %c" \
		MUX_LATCH_AUTH=/bin/true \
		MUX_LATCH_SLEEP="$T/bin/nosleep" \
		MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=3 \
		"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
	grep -v capabilities "$CMDLOG" | tail -1
}

# A remote that DECLARES it: the retry must use the flag.
_got=$(neg 0 'mux 0.31
attach-only 1')
[ "$_got" = 'mux go --attach-only proj' ] \
	|| fail "a remote declaring attach-only must be asked for it on retry.
Wanted [mux go --attach-only proj], got [$_got]"

# A remote that declares it ABSENT: the flag must NOT be used.
_got=$(neg 0 'mux 0.30
attach-only no')
[ "$_got" = 'mux go proj' ] \
	|| fail "a remote declaring 'attach-only no' must keep the creating form.
Wanted [mux go proj], got [$_got]"

# A remote too OLD to know the verb (exit 2 + usage): same, and no failure.
_got=$(neg 2 'mux: unknown verb: capabilities')
[ "$_got" = 'mux go proj' ] \
	|| fail "a remote too old for 'mux capabilities' must degrade to the
creating form, not break. Wanted [mux go proj], got [$_got]"

# AND THE FIRST ATTEMPT IS ALWAYS THE CREATING FORM, whatever the remote can
# do. You asked to latch onto something; refusing to build it on the first try
# would make latch useless for starting work.
: >"$CMDLOG"; rm -f "$ONCE"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	CMDLOG="$CMDLOG" ONCE="$ONCE" CAPRC=0 CAPOUT='attach-only 1' \
	MUX_LATCH_TRANSPORT="$T/bin/negotiate %h sh -lc %c" \
	MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=1 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
_first=$(grep -v capabilities "$CMDLOG" | head -1)
[ "$_first" = 'mux go proj' ] \
	|| fail "the FIRST attempt must create even when the remote supports
attach-only. Wanted [mux go proj], got [$_first]"

# A TRANSPORT FAILURE IS NOT A CAPABILITY VERDICT. If the query itself cannot
# get through, the remote's version is still unknown, and caching `no` would
# record a network outage as a permanent answer for the life of the run.
: >"$CMDLOG"; rm -f "$ONCE"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	CMDLOG="$CMDLOG" ONCE="$ONCE" CAPRC=255 CAPOUT= DROPS=3 \
	MUX_LATCH_TRANSPORT="$T/bin/negotiate %h sh -lc %c" \
	MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=4 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
[ "$(grep -c capabilities "$CMDLOG")" -ge 2 ] \
	|| fail "an unreachable capability query must leave the question OPEN and
ask again, not cache 'no' from a network failure. It asked
$(grep -c capabilities "$CMDLOG") time(s)."

# ... and once it HAS an answer it is not asked again. "Negotiated once" has to
# be true, not just claimed: `_cmd=$(_remote_cmd)` ran the composer in a
# SUBSHELL, so the cache it set was discarded every retry and latch re-queried
# the remote each time while the man page said otherwise. Nothing observable
# broke, which is why only a count catches it.
: >"$CMDLOG"; rm -f "$ONCE"
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	CMDLOG="$CMDLOG" ONCE="$ONCE" CAPRC=0 CAPOUT='attach-only 1' DROPS=3 \
	MUX_LATCH_TRANSPORT="$T/bin/negotiate %h sh -lc %c" \
	MUX_LATCH_AUTH=/bin/true MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=4 \
	"$HERE/libexec/mux-latch" box:proj >/dev/null 2>&1 || true
[ "$(grep -c capabilities "$CMDLOG")" = 1 ] \
	|| fail "an ANSWERED capability query must be cached for the run, and it
was asked $(grep -c capabilities "$CMDLOG") times across $(grep -vc \
capabilities "$CMDLOG") attempts"

# --- SINGLE FLIGHT: a second latch for the same target refuses -------
# N loops against one target is N credential prompts and N reconnect races.
mkdir -p "$T/run/mux-latch"
printf '%s\n' "$$" >"$T/run/mux-latch/box_proj.lock"
printf '0\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "a concurrent latch should refuse, got $_rc"
[ "$(n_tries)" = 0 ] || fail "a concurrent latch still attempted"
# A STALE lock from a dead pid must not wedge it forever.
printf '999999\n' >"$T/run/mux-latch/box_proj.lock"
printf '0\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 0 ] || fail "a stale lock from a dead pid blocked latch, got $_rc"

# --- the lock is also the LIVE REGISTRY of what this box is latched to -----
# Second job for a file that already did it perfectly: written at start, removed
# by the trap on every exit path, and carrying a pid so a killed run is
# detectable. The tray indicator reads this directory to decide which hosts to
# watch, so the format is a contract now, not an implementation detail.
#
# THE TARGET IS IN THE FILE BECAUSE THE FILENAME CANNOT HOLD IT. The name is
# sanitised through `tr -c`, so `manifold:api` becomes `manifold_api` and no
# reader can tell that from a host genuinely called `manifold_api`. A tray item
# polling the wrong hostname would draw `unknown` forever with nothing on screen
# to say why.
MAXT=1 _rc=$(latch 'hostwith:sess')
_lk=$T/run/mux-latch/hostwith_sess.lock
[ ! -e "$_lk" ] || fail "the lock outlived the run: the trap must remove it on
every exit path, or a finished latch leaves a phantom host in the tray"

# Written WHILE running, and readable. A transport that blocks lets the file be
# inspected mid-flight, which is the state the indicator actually sees.
cat >"$T/bin/slowtransport" <<EOF
#!/bin/sh
cat 2>/dev/null "$T/run/mux-latch/hostwith_sess.lock" >"$T/seen.lock" || true
exit 0
EOF
chmod +x "$T/bin/slowtransport"
MAXT=1 env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
	T_AUTH="$T_AUTH" T_PROBE="$T_PROBE" STATES="$STATES" TRIES="$TRIES" \
	AUTHLOG="$AUTHLOG" SCRIPT="$SCRIPT" \
	MUX_LATCH_TRANSPORT="$T/bin/slowtransport %h %s" \
	MUX_LATCH_AUTH="$T/bin/auth" MUX_LATCH_PROBE="$T/bin/probe" \
	MUX_LATCH_STATUS="$T/bin/status" MUX_LATCH_SLEEP="$T/bin/nosleep" \
	MUX_LATCH_BACKOFF=1 MUX_LATCH_MAX_TRIES=1 \
	"$HERE/libexec/mux-latch" 'hostwith:sess' >/dev/null 2>&1 || :
[ -s "$T/seen.lock" ] || fail "no lock file existed while latch was running"
_pid=$(sed -n 1p "$T/seen.lock")
_tgt=$(sed -n 2p "$T/seen.lock")
case $_pid in
''|*[!0-9]*) fail "line 1 of the lock must be the pid, got [$_pid]" ;;
esac
[ "$_tgt" = 'hostwith:sess' ] \
	|| fail "line 2 must be the target VERBATIM, got [$_tgt]. The filename is
sanitised (hostwith_sess), so the file is the only place a reader can recover
which host to poll."

# --- single flight still holds with two lines ------------------------------
# THE TRAP THIS GUARDS: reading the pid with `$(cat)` folds both lines into one
# string, and the numeric test then rejects a perfectly live pid because a
# newline is not a digit. Single-flight would stop holding SILENTLY -- a flap
# would again mean N loops and N credential prompts against one target, which is
# the storm the lock exists to prevent. `read -r` takes the first line only.
mkdir -p "$T/run/mux-latch"
_held=$T/run/mux-latch/heldhost.lock
printf '%s\n%s\n' "$$" 'heldhost' >"$_held"   # $$ is live: this test itself
_rc=$(MAXT=1 latch heldhost)
# THE LOCK FILE IS THE EVIDENCE, NOT THE EXIT CODE, and that order is the point.
# Mutating `read` back to `cat` leaves the exit code at 1 ANYWAY: the intruding
# run fails for its own unrelated reason and returns 1 by coincidence -- so an
# exit-code assertion passes while single flight is completely broken. What
# actually happens is worse than "it did not refuse": the intruder runs, and its
# own EXIT trap then deletes the HOLDER's lock, so the surviving latch is left
# unprotected and its host silently vanishes from the tray registry.
[ -s "$_held" ] || fail "a second latch to a held target ran anyway, and its
trap deleted the HOLDER's lock. Single flight is not holding: a flap now means
N loops and N credential prompts against one target, and the tray loses the
host. (The pid must be read with \`read\`, not \`cat\`.)"
[ "$_rc" = 1 ] || fail "a second latch to a held target must refuse with 1,
got $_rc"
rm -f "$_held"

pass
