#!/bin/sh
# test/mux-attach.t - mux must NEVER build a session inside a pane.
#
# mux_attach answers two independent questions:
#   1. am I genuinely in a live tmux pane?   (tty test -- $TMUX LEAKS into any
#      terminal spawned from a pane, so it cannot answer this)
#   2. is the target on the socket I am already on?
#
# They used to be one test: the tty check was nested inside the socket
# comparison, so a CROSS-socket target skipped it, fell through to the fresh
# attach path -- and that path deliberately unsets $TMUX, which is exactly what
# defeats tmux's own "sessions should be nested with care" guard. The result
# was a session nested inside a pane. It went unnoticed while the only other
# socket was a work one you seldom crossed, and became routine the moment the
# personal partition got a socket name of its own.
#
# tmux is stubbed so the three outcomes are distinguishable by the command
# attempted, with no pty needed.
set -eu
_name=mux-attach
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*has-session*)    exit 0 ;;          # the target is always already live
*list-sessions*)  printf 'proj %s\n' "$PROJDIR" ;;
*pane_tty*)       cat "$PANETTY" ;;  # what tmux says the pane's tty is
*session_path*)   printf '%s\n' "$PROJDIR" ;;
*window_index*)   printf '0\n' ;;
*pane_id*)        printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; PROJDIR=$T/proj; PANETTY=$T/panetty
export TMUXLOG PROJDIR PANETTY
PATH=$T/bin:$PATH; export PATH
printf 'scan %s 3\n' "$T" >"$T/conf/partitions/global.partition"

# go SOCKET_IN_TMUX : run `mux go proj` with $TMUX claiming that socket.
# TMUX_PANE is set, as it always is inside a pane.
go() {
	: >"$TMUXLOG"
	# `|| _r=$?` rather than a bare run: under `set -eu` a non-zero exit
	# would abort this function before it could report the code, and a
	# non-zero exit is one of the outcomes under test.
	_r=0
	( cd "$T/proj" && env -u MUX_SHARE MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" TMUX="/tmp/fake/$1,123,0" TMUX_PANE=%9 \
		"$HERE/bin/mux" go proj ) >"$T/out" 2>&1 || _r=$?
	printf '%s' "$_r"
}
did() { grep -q "$1" "$TMUXLOG"; }

# --- genuinely in a pane: the tty mux sees IS the pane's tty ----------------
# Captured exactly as mux_attach captures it, so this works whether or not the
# harness itself has a controlling terminal (it does not, under `test/run`).
_mine=$(tty 2>/dev/null || true)
printf '%s\n' "$_mine" >"$PANETTY"

# Same socket -> switch this client's view. Never an attach, which would nest.
_rc=$(go global)
[ "$_rc" = 0 ] || fail "same-socket switch exited $_rc: $(cat "$T/out")"
did 'switch-client -t =proj' || fail "same socket did not switch-client"
did 'attach-session' && fail "same socket attached (would nest) instead"

# DIFFERENT socket -> refuse. switch-client cannot cross a socket and an
# attach from inside a pane nests, so there is no safe move: say so.
_rc=$(go otherpart)
[ "$_rc" = 0 ] && fail "a cross-socket target from a pane should refuse"
did 'attach-session' && fail "cross-socket ATTACHED from a pane -- nests"
grep -q 'would nest' "$T/out" || fail "no explanation: $(cat "$T/out")"
grep -q 'Detach first' "$T/out" || fail "refusal offers no way forward"

# --- NOT in a pane: $TMUX is leaked from a terminal spawned by one ----------
# The tty will not match, so this must attach normally rather than refuse --
# it is the case that makes a leaked $TMUX harmless.
printf '%s-not-mine\n' "$_mine" >"$PANETTY"
_rc=$(go global)
[ "$_rc" = 0 ] || fail "a leaked \$TMUX should attach, exited $_rc"
did 'attach-session -t =proj' || fail "leaked \$TMUX did not attach"
did 'switch-client' && fail "leaked \$TMUX switched a client that is not ours"

# ... and cross-socket from OUTSIDE a pane is fine: nothing to nest inside.
_rc=$(go otherpart)
[ "$_rc" = 0 ] || fail "cross-socket from outside a pane should attach"
did 'attach-session -t =proj' \
	|| fail "cross-socket outside a pane did not attach"

pass
