#!/bin/sh
# test/mux-latch-hooks.t - the SHIPPED latch hooks, which were never once run.
#
# A function-level coverage measurement found share/latch/ssh-auth and
# share/latch/ssh-probe completely DARK: every latch test stubs the seams, which
# is right for testing the state machine and means the real hooks had no test at
# all. ssh-classify was covered only because mux-latch.t happens to use the real
# one.
#
# ssh-auth IS THE SAFETY-CRITICAL ONE. Its answer decides the `blocked` state,
# and `blocked` exists to make the credential-prompt storm impossible: every
# attempt against a host with no live credential is a password prompt or a
# hardware-key touch. So the two ways it can be wrong are both bad and not
# symmetric --
#
#   answering 0 with no credential live  -> latch attempts, and the storm is on
#   answering 1 with a credential live   -> latch waits forever for nothing
#
# -- and 78 ("cannot tell") exists so neither has to be guessed. None of that
# was verified by anything until now.
#
# ssh and ssh-add are STUBBED ON PATH, which is the only way to drive the three
# answers deterministically: the real ones depend on an agent, a control master
# and a network this test must not touch.
set -eu
_name=mux-latch-hooks
. "$(dirname "$0")/lib.sh"

AUTH=$HERE/share/latch/ssh-auth
PROBE=$HERE/share/latch/ssh-probe
[ -x "$AUTH" ]  || fail "share/latch/ssh-auth is missing or not executable"
[ -x "$PROBE" ] || fail "share/latch/ssh-probe is missing or not executable"

mkdir -p "$T/bin"
# The ordinary tools the hooks need, since PATH is replaced wholesale below.
for _c in sed awk grep cat rm mktemp printf timeout; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done

# ssh stub. OCHECK is `ssh -O check`'s exit; SSHRC and SSHERR are a real
# connection's. Recorded so a test can assert what was NOT attempted.
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SSHLOG"
case "$*" in
*"-O check"*) exit "${OCHECK:-1}" ;;
esac
[ -n "${SSHERR:-}" ] && printf '%s\n' "$SSHERR" >&2
exit "${SSHRC:-0}"
EOF
cat >"$T/bin/ssh-add" <<'EOF'
#!/bin/sh
printf 'ssh-add %s\n' "$*" >>"$SSHLOG"
exit "${ADDRC:-0}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/ssh-add"
SSHLOG=$T/sshlog; export SSHLOG

ask() {   # <hook> [args...] -> its exit code, with the env already set
	: >"$SSHLOG"
	_r=0
	env PATH="$T/bin" SSHLOG="$SSHLOG" \
		OCHECK="${OCHECK:-1}" ADDRC="${ADDRC:-0}" \
		SSHRC="${SSHRC:-0}" SSHERR="${SSHERR:-}" \
		MUX_SSH_PROBE_TIMEOUT="${MUX_SSH_PROBE_TIMEOUT:-10}" \
		"$@" >/dev/null 2>&1 || _r=$?
	echo "$_r"
}
tried() { grep -c . "$SSHLOG" 2>/dev/null || true; }

# --- ssh-auth: a LIVE CONTROL MASTER is the strongest yes ---------------
# It means the connection is already authenticated, so no credential is needed
# at all. Cheapest check, so it goes first -- and it must SHORT-CIRCUIT: asking
# ssh-add afterwards could answer 1 on an empty agent and turn a working
# connection into `blocked`.
[ "$(OCHECK=0 ADDRC=1 ask "$AUTH" box)" = 0 ] \
	|| fail "a live control master must answer 0 even with an EMPTY agent:
the connection is already authenticated, so there is nothing to prompt for"
grep -q 'ssh-add' "$SSHLOG" \
	&& fail "ssh-add was consulted after a live control master already
answered. That is the ordering that turns a working connection into a wait."

# --- ssh-add's three exits ARE the three answers ------------------------
[ "$(OCHECK=1 ADDRC=0 ask "$AUTH" box)" = 0 ] \
	|| fail "keys loaded (ssh-add 0) must answer 0: attempt it"
[ "$(OCHECK=1 ADDRC=1 ask "$AUTH" box)" = 1 ] \
	|| fail "an agent running but EMPTY (ssh-add 1) must answer 1. That is
the whole prompt-storm guard: latch must not attempt, because every attempt is
a prompt, and a human has to add a key before anything changes."
[ "$(OCHECK=1 ADDRC=2 ask "$AUTH" box)" = 78 ] \
	|| fail "NO AGENT AT ALL (ssh-add 2) must answer 78, not 1. It is not
the same claim: mux cannot see whether a password, a certificate or a GSSAPI
ticket would work, so 1 would park latch in blocked forever on a box that
would have connected fine."

# 78 for anything it genuinely cannot answer, rather than a guess either way.
[ "$(ask "$AUTH")" = 78 ] || fail "asked about no host, it must answer 78"
[ "$(OCHECK=1 ADDRC=9 ask "$AUTH" box)" = 78 ] \
	|| fail "an unrecognised ssh-add exit must be 78 (cannot tell), since a
tool failing in a way it did not anticipate has not answered"

# --- it NEVER OPENS A CONNECTION ---------------------------------------
# The entire reason `blocked` can poll: auth liveness is observable without
# connecting, so waiting costs nothing and raises no prompt. A hook that
# connected would make the poll the very storm it prevents.
: >"$SSHLOG"
OCHECK=1 ADDRC=1 ask "$AUTH" box >/dev/null
while IFS= read -r _l; do
	case $_l in
	*"-O check"*|"ssh-add "*) ;;
	*) fail "ssh-auth ran something that can open a connection: [$_l].
Polling this while blocked would then raise a prompt per poll, which is the
storm it exists to prevent." ;;
	esac
done <"$SSHLOG"

# --- ssh-probe: 0 usable, 1 not reachable, 78 cannot tell --------------
[ "$(SSHRC=0 ask "$PROBE" box)" = 0 ] || fail "a working connection is 0"
[ "$(OCHECK=0 ask "$PROBE" box)" = 0 ] \
	|| fail "a live control master answers 0 without connecting"
for _m in 'Connection refused' 'No route to host' 'Network is unreachable' \
	'ssh: Could not resolve hostname box: Name or service not known' \
	'Name or service not known' 'Connection timed out'; do
	_g=$(SSHRC=255 SSHERR="$_m" ask "$PROBE" box)
	[ "$_g" = 1 ] || fail "[$_m] is a plain connection failure and must
answer 1 (not reachable, retry), got $_g"
done

# AN AUTH PROBLEM IS NOT AN UNREACHABLE HOST. Answering 1 here would put latch
# in the retry loop for something only a human can fix, and auth has its own
# hook for exactly that reason.
for _m in 'Permission denied (publickey).' 'Host key verification failed.'; do
	_g=$(SSHRC=255 SSHERR="$_m" ask "$PROBE" box)
	[ "$_g" = 78 ] || fail "[$_m] is a refusal, not unreachability, so the
probe must say 78 (cannot tell) and leave it to auth and classify. Got $_g"
done
[ "$(ask "$PROBE")" = 78 ] || fail "asked about no host, the probe answers 78"

# --- the probe is BOUNDED -----------------------------------------------
# ConnectTimeout is what actually bounds ssh (measured: a peer that accepts and
# then says nothing hangs forever without it), and timeout(1) is the backstop,
# because a probe is bounded BY CONTRACT and should not depend on which ssh
# option happens to enforce it.
grep -q 'ConnectTimeout' "$PROBE" \
	|| fail "the probe no longer passes ConnectTimeout. Measured: with it a
silent peer gives up in 5s, without it ssh was still waiting after 40s, and
ServerAliveInterval does not help because it only starts once a session exists."
: >"$SSHLOG"
SSHRC=124 ask "$PROBE" box >/dev/null
[ "$(SSHRC=124 ask "$PROBE" box)" = 1 ] \
	|| fail "timeout(1)'s own code (124) means the host took longer than a
probe is allowed to take. That is a definite 'not usable right now', not a
'cannot tell': if it will not talk within the bound, an attach will not fare
better."

pass
