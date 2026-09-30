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
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/rt/agent-state/default"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
# `worksess` lives in the `work` partition and is listed here because the
# stub answers one set for every socket. It is invisible to the default
# partition's cases either way: the choice comes from the state RECORDS,
# and its record is written under agent-state/work.
*list-sessions*)    printf 'alpha\nbravo\ncharlie\nworksess\n' ;;
# ORDER MATTERS, and it bit: the list-clients FORMAT contains
# `#{client_name}`, so a `*client_name*` arm placed first swallows it and
# returns a single tty: the headless case then looked like it could not
# resolve a client when the code was fine. Most specific arm first.
*list-clients*)     [ -n "${MUX_NB_NOCLIENTS:-}" ] && exit 0
                    printf '100 /dev/pts/1\n900 /dev/pts/9\n300 /dev/pts/3\n' ;;
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

# bravo blocked since epoch 200, charlie since 100: charlie has waited
# LONGER, so charlie is the jump. (alpha is the client's own session.)
agent_rec "$T/rt/agent-state/default/p1" blocked %1 200 bravo x
agent_rec "$T/rt/agent-state/default/p2" blocked %2 100 charlie x

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

# Nothing blocked: no jump, and SILENCE; it runs from a key binding, whose
# stdout tmux would pop in a view-mode buffer over the pane.
rm -f "$T/rt/agent-state/default/p1"
_got=$(run '/dev/pts/7')
[ -z "$_got" ] || fail "nothing blocked: expected no switch, got [$_got]"

# No client and NOTHING ATTACHED to resolve one from: fail loud, non-zero.
#
# This used to read "no session to resolve one from", because outside tmux the
# verb refused outright. It does not any more: a remote caller arriving over
# a transport has no pane and never will, and a tray item exists only when a
# latch does, so there IS a client. The refusal now turns on whether anything
# is ATTACHED, which is the fact that actually decides whether a switch is
# possible. Asserted with the stub answering no clients at all.
if env -u MUX_SHARE -u TMUX MUX_NB_NOCLIENTS=1 \
  "$HERE/bin/mux" next-blocked >/dev/null 2>&1; then
  fail "no client attached anywhere: expected a non-zero exit"
fi

# --- HEADLESS: no pane, no $TMUX, which is how a REMOTE caller arrives -----
# The tray indicator reaches a latched host over the same transport it polls
# with, so there is no pane to resolve a client from. That used to exit 1 and
# say "must run in a session", which made the whole cross-machine click
# impossible, and a tray item exists ONLY when a latch does, so a client is
# by definition attached.
#
# The partition is `default` here, matching the namespace the records above
# were written under: headless, the socket comes from MUX_CTX_PARTITION rather
# than from $TMUX, and pointing it elsewhere finds an empty state dir and
# correctly does nothing, which reads exactly like a broken client lookup.
#
# MOST RECENTLY ACTIVE wins. Asserted with the busiest client deliberately NOT
# first in the list, so an implementation that just takes the first line fails
# here rather than passing by accident.
: >"$TMUXLOG"
# Seed its own blocked session: the cases above deliberately clear both, so
# without this the helper correctly does nothing and the assertion below
# would fail for a reason that has nothing to do with client resolution.
agent_rec "$T/rt/agent-state/default/p9" blocked %9 100 charlie x
# The HELPER directly, not through `bin/mux`: the front end resolves the
# partition itself and would override MUX_CTX_PARTITION here, pointing at an
# empty state dir. That the verb REACHES the helper is already proved by the
# cases above; what is under test here is how it picks a client.
env -u MUX_SHARE -u TMUX MUX_CTX_PARTITION=default \
  "$HERE/libexec/mux-next-blocked" >/dev/null 2>&1 || true
case "$(cat "$TMUXLOG")" in
*"/dev/pts/9"*) ;;
*) fail "headless did not pick the most recently active client: got
[$(cat "$TMUXLOG")]; wanted the one with the highest client_activity" ;;
esac

# --- --partition SCOPES THE WHOLE RUN --------------------------------------
# One host publishes one tray item per partition now, so a click on the `work`
# item has to jump to WORK's blocked session. Without this every item on a
# host did the same thing, and did it plausibly, landing on a real session
# that simply was not the one you clicked.
#
# BOTH HALVES ARE ASSERTED, because they resolve from different places and
# have already disagreed once: the SOCKET (`tmux -L work`) and the STATE
# DIRECTORY (agent-state/work). Asking the right server and then reading
# another partition's records finds nothing blocked and exits 0 having done
# nothing, which is indistinguishable from "nothing needs you".
#
# The discriminator is the `default` record left live above: if the option
# were ignored, this would switch to charlie rather than to worksess.
mkdir -p "$T/rt/agent-state/work"
agent_rec "$T/rt/agent-state/work/p1" blocked %1 50 worksess x
: >"$TMUXLOG"
env -u MUX_SHARE -u TMUX MUX_CTX_PARTITION=default \
  "$HERE/libexec/mux-next-blocked" --partition work >/dev/null 2>&1 || true
case "$(cat "$TMUXLOG")" in
*"=worksess"*) ;;
*) fail "--partition did not reach the partition's STATE: got
[$(cat "$TMUXLOG")]; it read another partition's records" ;;
esac
case "$(cat "$TMUXLOG")" in
*"-L work"*) ;;
*) fail "--partition did not reach the partition's SERVER: got
[$(cat "$TMUXLOG")]; the switch went to whichever socket was default" ;;
esac

# A bare --partition is a usage error, not a silent fall back to the caller's
# own partition: a click composed without its name would then jump somewhere
# plausible and wrong.
_rc=0
env -u MUX_SHARE -u TMUX "$HERE/libexec/mux-next-blocked" --partition \
  >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "--partition with no name must exit 2, got $_rc"
_rc=0
env -u MUX_SHARE -u TMUX "$HERE/libexec/mux-next-blocked" --nope \
  >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown option must exit 2, got $_rc"

# ... and with nothing attached at all it says so rather than switching blind.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*) printf 'alpha\n' ;;
*list-clients*)  ;;
*switch-client*) printf 'SWITCH %s\n' "$*" >>"$TMUXLOG" ;;
esac
EOF
chmod +x "$T/bin/tmux"
: >"$TMUXLOG"
_rc=0
env -u MUX_SHARE -u TMUX MUX_CTX_PARTITION=default \
  "$HERE/libexec/mux-next-blocked" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "with no client attached it must exit 1, got $_rc"
[ ! -s "$TMUXLOG" ] || fail "it switched something with no client attached"

pass
