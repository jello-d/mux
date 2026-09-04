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

# state files are "state session window pane epoch notif-id"
printf 'blocked alpha 0 0 100 x\n' >"$XDG_RUNTIME_DIR/agent-state/global/p1"
printf 'working bravo 0 0 200 x\n' >"$XDG_RUNTIME_DIR/agent-state/global/p2"
printf 'idle    wsess 0 0 300 x\n' >"$XDG_RUNTIME_DIR/agent-state/work/p1"

sum() {
	env -u TMUX -u MUX_SHARE MUX_DIR="$MUX_DIR" MUX_CACHE="$MUX_CACHE" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
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
printf 'blocked charlie 0 0 150 x\n' >"$XDG_RUNTIME_DIR/agent-state/global/p3"
eq worst-wins "$(sum global)" "blocked 2"

pass
