#!/bin/sh
# test/mux-next-blocked.t - `mux next-blocked` end to end: that the verb REACHES
# libexec/mux-next-blocked at all (it used to hit the zero-arity gate, so
# `prefix b` popped usage text instead of jumping), that the oldest blocked
# session wins, and that the client argument survives the dispatch.
#
# tmux is stubbed in $T/bin, so nothing real is queried and no server is
# started; the agent-state dir is a scratch $XDG_RUNTIME_DIR. Nothing outside T.
set -eu
_name=mux-next-blocked
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/rt/agent-state/default"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*)    printf 'alpha\nbravo\ncharlie\n' ;;
*client_name*)      printf '/dev/pts/7\n' ;;
*client_session*)   printf 'alpha\n' ;;
*switch-client*)    printf 'SWITCH %s\n' "$*" >>"$TMUXLOG" ;;
esac
EOF
chmod +x "$T/bin/tmux"

TMUXLOG=$T/log
export TMUXLOG
XDG_RUNTIME_DIR=$T/rt
export XDG_RUNTIME_DIR
PATH=$T/bin:$PATH
export PATH

# run [ARG...] : `mux next-blocked` with a fresh log, echoing what it switched
# to. $MUX_SHARE is scrubbed so a real install cannot leak in, and $TMUX is
# forced to a dummy: the bare form's "are we in a session" guard reads it, and
# every tmux call it gates is the stub anyway.
run() {
	: >"$TMUXLOG"
	env -u MUX_SHARE TMUX="$T/default,0,0" \
		"$HERE/bin/mux" next-blocked "$@" \
		|| fail "next-blocked exited $?"
	cat "$TMUXLOG"
}

# bravo blocked since epoch 200, charlie since 100 -- charlie has waited
# LONGER, so charlie is the jump. (alpha is the client's own session.)
printf 'blocked bravo 0 0 200 x\n'   >"$T/rt/agent-state/default/p1"
printf 'blocked charlie 0 0 100 x\n' >"$T/rt/agent-state/default/p2"

# An explicit CLIENT (how the `prefix b` binding calls it) must reach the
# helper and be passed on to switch-client -c.
_got=$(run '/dev/pts/7')
_exp='SWITCH switch-client -c /dev/pts/7 -t =charlie'
[ "$_got" = "$_exp" ] || fail "explicit client: got [$_got] want [$_exp]"

# The bare CLI form resolves its own client (stubbed as the same tty).
_got=$(run)
[ "$_got" = "$_exp" ] || fail "bare form: got [$_got] want [$_exp]"

# Once charlie clears, bravo is next in the urgency order.
rm -f "$T/rt/agent-state/default/p2"
_got=$(run '/dev/pts/7')
_exp='SWITCH switch-client -c /dev/pts/7 -t =bravo'
[ "$_got" = "$_exp" ] || fail "next in order: got [$_got] want [$_exp]"

# Nothing blocked: no jump, and SILENCE -- it runs from a key binding, whose
# stdout tmux would pop in a view-mode buffer over the pane.
rm -f "$T/rt/agent-state/default/p1"
_got=$(run '/dev/pts/7')
[ -z "$_got" ] || fail "nothing blocked: expected no switch, got [$_got]"

# No client and no session to resolve one from: fail loud, non-zero.
if env -u MUX_SHARE -u TMUX "$HERE/bin/mux" next-blocked >/dev/null 2>&1; then
	fail "no client outside a session: expected a non-zero exit"
fi

pass
