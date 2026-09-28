#!/bin/sh
# test/mux-agent-summary.t - `mux agent-summary` is the HEADLESS reader: the
# tray indicator polls it from a desktop daemon with no tmux client, no $TMUX
# and no cwd of consequence.
#
# That makes it the one consumer of mux-agent-state.sh whose namespace cannot
# come from $TMUX, and it is exactly where a stale default hid. It used to fall
# back to the literal name `default` -- the old tmux socket basename. When the
# personal partition became `global` that directory stopped existing, so the
# indicator read an empty dir and reported "none 0" indefinitely: no error, no
# clue, just a tray that never lit up.
#
# So the assertions worth having are about RESOLUTION, not about the ranking
# (mux-agent-state.sh owns that and the strip shares it).
set -eu
_name=mux-agent-summary
. "$(dirname "$0")/lib.sh"

XDG_RUNTIME_DIR=$T/run
MUX_DIR=$T/conf
MUX_CACHE=$T/cache
export XDG_RUNTIME_DIR MUX_DIR MUX_CACHE
mkdir -p "$XDG_RUNTIME_DIR/agent-state/global" \
	"$XDG_RUNTIME_DIR/agent-state/work" "$MUX_DIR/partitions"

# agent_rec writes the record; test/lib.sh owns the field order, so a format
# change lands in one place instead of being re-typed in every fixture.
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p1" blocked %1 100 alpha x
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p2" working %2 200 bravo x
agent_rec "$XDG_RUNTIME_DIR/agent-state/work/p1"   idle    %3 300 wsess x

# A tmux that answers ONE question: does partition X have a client attached?
# $WATCHED is the set that does. Stubbed because --attached is the only part
# of this verb that asks tmux anything at all, and the whole point of the rest
# of the file is that it answers with no tmux client anywhere.
mkdir -p "$T/bin"
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

sum() {
	env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" MUX_CACHE="$MUX_CACHE" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH="$T/bin:$PATH" \
		WATCHED="${WATCHED:-}" \
		"$HERE/bin/mux" agent-summary "$@" 2>&1
}
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- headless, no context configured: the BASELINE partition ---------------
# The regression: this must be `global`, not the retired `default`.
eq headless "$(sum)" "blocked 1"

# An explicit namespace still wins.
eq explicit-global "$(sum global)" "blocked 1"
eq explicit-work "$(sum work)" "idle 1"

# A namespace with no state is "none 0" -- the honest answer, and the one the
# stale default was accidentally producing for a namespace that DID have state.
eq empty-ns "$(sum nosuchpartition)" "none 0"

# --- headless, WITH a context-command: the resolved partition --------------
# A tray daemon on a box whose context resolves elsewhere must follow it,
# rather than always reading the baseline.
printf '#!/bin/sh\necho work\n' >"$MUX_DIR/cc"; chmod +x "$MUX_DIR/cc"
printf 'context-command cc\n' >"$MUX_DIR/config"
printf 'scan %s 1\n' "$T" >"$MUX_DIR/partitions/work.partition"
eq resolved "$(sum)" "idle 1"
# ... and an explicit argument still overrides the resolved context.
eq explicit-beats-ctx "$(sum global)" "blocked 1"
rm -f "$MUX_DIR/config"

# --- the worst state wins, and the count is of sessions in THAT state ------
agent_rec "$XDG_RUNTIME_DIR/agent-state/global/p3" blocked %3 150 charlie x
eq worst-wins "$(sum global)" "blocked 2"

# --- --all: EVERY partition, in one call ----------------------------------
# The tray polls a remote over ssh; asking per partition would multiply that
# cost by the partition count on every tick, for a signal that changes on
# human timescales. One question, one answer.
#
# Two namespaces exist in this fixture (global and work), so this also pins
# that --all reports the OTHER partition, not just the caller's -- a version
# that quietly answered for one would pass any single-line assertion.
_o=$(sum --all)
printf '%s\n' "$_o" | grep -q '^global blocked 2$' \
	|| fail "--all did not report the caller partition correctly: [$_o]"
printf '%s\n' "$_o" | grep -q '^work idle 1$' \
	|| fail "--all did not report the OTHER partition: [$_o]"
[ "$(printf '%s\n' "$_o" | grep -c .)" = 2 ] \
	|| fail "--all reported $(printf '%s\n' "$_o" | grep -c .) lines, want 2"

# --- --attached: only what somebody is LOOKING at -------------------------
# A TRAY ITEM MEANS A HUMAN IS LOOKING AT THIS. Remotely that is exactly what
# a latch already encodes; locally it is a client attached to that partition's
# server. Reported live: a second local partition had a running server and a
# live agent, and no terminal window anywhere showing it, so the tray carried
# an item nobody could act on.
#
# STATE FILES ARE NOT THE ANSWER and that is why this cannot be inferred from
# the directory -- they outlive their server, and a server can outlive the last
# client. Both look identical from the state dir.
WATCHED=global
_o=$(WATCHED=global sum --all --attached)
eq attached-only "$_o" "global blocked 2"

# The OTHER direction, asserted separately: watching the other one reports the
# other one. A version that hardcoded the caller's partition would pass the
# assertion above and nothing else.
_o=$(WATCHED=work sum --all --attached)
eq attached-other "$_o" "work idle 1"

# Both attached, both reported -- so the filter is not simply keeping one.
_o=$(WATCHED="global work" sum --all --attached | grep -c .)
eq attached-both "$_o" "2"

# NOTHING attached, nothing reported, and that includes the caller's own
# partition. The guarantee below (always at least one line) is deliberately
# NOT extended to --attached: the whole point of the flag is that an unwatched
# partition is not reported, and the caller's own is not exempt from the
# question it just asked. This is what lets the tray empty when you detach.
_o=$(WATCHED= sum --all --attached)
[ -z "$_o" ] || fail "--attached reported something with nothing attached:
[$_o]"

# ... while the BARE --all is untouched by any of it, because its contract is
# that it answers headless, with no tmux client anywhere.
_o=$(WATCHED= sum --all | grep -c .)
eq all-unfiltered "$_o" "2"

# The caller's own partition appears even when NOTHING has any state, so a
# consumer always gets at least one line -- the same reason the tray always
# carries the local host rather than emptying when nothing is latched.
#
# Asserted by emptying the lot rather than by setting MUX_CTX_PARTITION:
# mux_ctx_resolve OVERWRITES that variable from the context command, so an
# env-var fixture would silently test the resolved partition instead of the
# one it named. That override has now cost three separate debugging sessions.
rm -rf "$XDG_RUNTIME_DIR/agent-state"
_o=$(sum --all)
[ "$(printf '%s\n' "$_o" | grep -c .)" = 1 ] \
	|| fail "with no state at all, --all should still answer once: [$_o]"
case $_o in
*" none 0") ;;
*) fail "with no state at all, --all said [$_o]" ;;
esac

pass
