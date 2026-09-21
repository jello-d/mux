#!/bin/sh
# test/mux-attach-only.t - `mux go --attach-only`: attach, or refuse. Never
# create.
#
# WHO ASKS FOR THIS AND WHY. `mux latch` holds a remote attachment open across
# drops. Its first attempt may create, since you asked to latch onto something,
# but a REattach that finds nothing means the far side rebooted -- and building
# a fresh empty session where your work used to be is the worst answer
# available. It looks like success, it is indistinguishable from success on the
# status bar, and the work is gone.
#
# So the flag's value is entirely in the NEGATIVE case, which is what this file
# asserts. A version of it that attaches correctly and also creates when it
# should not has no value at all.
#
# THE MESSAGE IS PART OF THE CONTRACT. share/latch/ssh-classify matches "no such
# session" to produce the `gone` state, so the wording is load-bearing rather
# than cosmetic and is asserted here and end-to-end at the bottom.
set -eu
_name=mux-attach-only
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf" "$T/proj"
TMUXLOG=$T/tmuxlog; export TMUXLOG
# A stub tmux whose has-session answer is driven by a file, so one test can be
# the same session present and absent.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*has-session*)
	[ -f "$LIVEFLAG" ] && exit 0
	exit 1 ;;
*list-sessions*)
	[ -f "$LIVEFLAG" ] || exit 1
	printf 'proj %s\n' "$T/proj" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
LIVEFLAG=$T/live; export LIVEFLAG
PATH=$T/bin:$PATH; export PATH

mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" EDITOR=/bin/true \
		"$HERE/bin/mux" "$@" </dev/null ) 2>&1
}
rc() {   # run, print the exit code
	_r=0
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" EDITOR=/bin/true \
		"$HERE/bin/mux" "$@" </dev/null ) >/dev/null 2>&1 || _r=$?
	echo "$_r"
}

# --- THE LOAD-BEARING CASE: not live, so REFUSE --------------------------
rm -f "$LIVEFLAG"
: >"$TMUXLOG"
_out=$(mux go --attach-only proj || true)
case $_out in
*"no such session"*) ;;
*) fail "--attach-only on a dead session must say 'no such session', got:
$_out" ;;
esac
[ "$(rc go --attach-only proj)" = 1 ] \
	|| fail "--attach-only on a dead session must exit 1"

# It must not have tried to BUILD anything. A refusal that still created the
# session would satisfy the message assertion above and defeat the entire point,
# so this checks the tmux calls rather than the words.
grep -q 'new-session' "$TMUXLOG" \
	&& fail "--attach-only created a session. That is the exact failure this
flag exists to prevent: after a reboot it hands you an empty session where your
work was, and nothing about it looks wrong."

# --- a session that IS live attaches normally ---------------------------
: >"$LIVEFLAG"
: >"$TMUXLOG"
[ "$(rc go --attach-only proj)" = 0 ] \
	|| fail "--attach-only on a LIVE session must attach and exit 0"
grep -q 'attach-session\|switch-client' "$TMUXLOG" \
	|| fail "--attach-only did not attach a live session; tmux saw:
$(cat "$TMUXLOG")"
grep -q 'new-session' "$TMUXLOG" \
	&& fail "--attach-only rebuilt a session that was already live"
rm -f "$LIVEFLAG"

# --- without the flag, the same call CREATES ----------------------------
# The contrast is the assertion: if plain `go` also refused, the test above
# would pass for the wrong reason and prove nothing about the flag.
# Bare `go`, so the name is DERIVED from the directory: a typed name nothing
# knows is refused by design (a new session and a typo are identical from the
# input alone), which would make this contrast pass for the wrong reason.
: >"$TMUXLOG"
mux go >/dev/null 2>&1 || true
grep -q 'new-session' "$TMUXLOG" \
	|| fail "plain 'mux go' no longer creates, so the --attach-only assertion
above proves nothing. tmux saw:
$(cat "$TMUXLOG")"

# ... and the same derived-name call WITH the flag still refuses, which is the
# pair that matters: identical invocation, one word of difference, opposite
# outcome.
: >"$TMUXLOG"
mux go --attach-only >/dev/null 2>&1 || true
grep -q 'new-session' "$TMUXLOG" \
	&& fail "--attach-only created a session when the name was DERIVED rather
than typed. The guard must not depend on how the name was arrived at."

# --- it is declared, so a remote caller can ASK -------------------------
# The whole point of the manifest: attach-only was 'no' one release ago and a
# consumer that asked then gets a different answer now, with no version sniffing
# anywhere. A flag that works but is not declared is one latch cannot use.
_caps=$(env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
	"$HERE/bin/mux" capabilities 2>&1)
case $_caps in
*"attach-only 1"*) ;;
*) fail "attach-only is implemented but not advertised as a contract, so
latch would still have to discover it by failure. Got:
$_caps" ;;
esac

# --- END TO END WITH THE CLASSIFIER -------------------------------------
# The refusal must become the `gone` state, or latch reports a rebooted host as
# a generic failure and the operator learns nothing. This couples the two files
# deliberately: the message is a contract between them, and a reword that breaks
# it should fail HERE rather than in production six weeks later.
_e=$T/stderr
rm -f "$LIVEFLAG"
( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
	MUX_CACHE="$T/cache" "$HERE/bin/mux" go --attach-only proj \
	</dev/null ) >/dev/null 2>"$_e" || true
_state=$("$HERE/share/latch/ssh-classify" 1 "$_e")
[ "$_state" = gone ] \
	|| fail "the --attach-only refusal must classify as 'gone', got '$_state'.
share/latch/ssh-classify matches 'no such session'; one side was reworded
without the other, and latch would report a rebooted host as a plain refusal.
Its stderr was:
$(cat "$_e")"

pass
