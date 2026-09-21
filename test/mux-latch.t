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
tail -n +2 "$SCRIPT" >"$SCRIPT.t" 2>/dev/null || :
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
printf '1 mux: no such session: proj\n' >"$SCRIPT"
_rc=$(latch box:proj)
[ "$_rc" = 1 ] || fail "a vanished session should exit non-zero, got $_rc"
[ "$(n_tries)" = 1 ] || fail "a vanished session was retried"
case "$(seq_of)" in
*gone*) ;;
*) fail "a vanished session was not reported as gone: [$(seq_of)]" ;;
esac

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

pass
