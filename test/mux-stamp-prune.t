#!/bin/sh
# test/mux-stamp-prune.t - mux clears the litter mux makes.
#
# Every tmux server that sources mux.tmux runs `mux themes load`, which writes
# $MUX_CACHE/mux-themes.<socket>.sha so an unchanged palette is never pushed
# twice. Nothing ever removed one. That includes the throwaway `-L scratch`
# servers a test suite spins up, so the directory only ever grew: 60 stamps had
# accumulated on this box from 59 sockets that no longer existed.
#
# Not harmful -- a stamp is a cache -- but it is litter mux made, and a
# directory that only grows is one nobody will ever audit. `load` is the moment
# to clear it because it is the only one needing no decision: a prune verb has
# to be remembered and a timer has to be installed, whereas every new server
# already runs load, so the steady state becomes however many servers you
# actually have.
#
# The liveness test is the same one heal() uses, and it is the only thing that
# can be asserted here: whether a stamp's socket still has a server behind it.
set -eu
_name=mux-stamp-prune
. "$(dirname "$0")/lib.sh"

command -v tmux >/dev/null 2>&1 || {
	printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

SOCK=muxprune$$
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT INT TERM

STAMPS=$T/cache
mkdir -p "$STAMPS"
stamp() { printf 'somehash\n' >"$STAMPS/mux-themes.$1.sha"; }
have()  { [ -e "$STAMPS/mux-themes.$1.sha" ]; }
n_stamps() {
	_n=0
	for _f in "$STAMPS"/*; do [ -e "$_f" ] && _n=$((_n + 1)); done
	echo "$_n"
}

tmux -L "$SOCK" kill-server 2>/dev/null || true
tmux -L "$SOCK" new-session -d -s keepme 'sleep 120' 2>/dev/null \
	|| { printf 'skip %s (cannot start a tmux server)\n' "$_name"; exit 0; }

# One live socket, three that are gone. The live one is the assertion that
# matters: a prune that removed everything would also pass a count check.
stamp "$SOCK"
stamp deadone
stamp deadtwo
stamp "a-name-with-dashes"
[ "$(n_stamps)" = 4 ] || fail "setup: expected 4 stamps, got $(n_stamps)"

env MUX_CACHE="$STAMPS" MUX_SHARE="$HERE/share" MUX_DIR="$T/conf" \
	"$HERE/libexec/mux-themes" prune >/dev/null 2>&1 \
	|| fail "mux themes prune exited non-zero"

have "$SOCK" || fail "THE LIVE SOCKET'S STAMP WAS PRUNED. Its server is up, so
the next load would re-push a palette that was already correct -- and a prune
that deletes everything passes any count-based assertion, which is why this is
checked by name."
have deadone && fail "a stamp whose socket has no server survived the prune"
have deadtwo && fail "a stamp whose socket has no server survived the prune"
have "a-name-with-dashes" \
	&& fail "a dead stamp whose KEY contains dashes survived; the key is
parsed out of the filename, so a name with punctuation in it must still parse"
[ "$(n_stamps)" = 1 ] || fail "expected only the live stamp to remain, got
$(for _f in "$STAMPS"/*; do [ -e "$_f" ] && printf '%s ' "${_f##*/}"; done)"

# --- IDEMPOTENT, and safe on an empty or absent directory --------------
env MUX_CACHE="$STAMPS" MUX_SHARE="$HERE/share" MUX_DIR="$T/conf" \
	"$HERE/libexec/mux-themes" prune >/dev/null 2>&1 \
	|| fail "a second prune exited non-zero"
have "$SOCK" || fail "the live stamp did not survive a second prune"

rm -f "$STAMPS"/mux-themes.*.sha
env MUX_CACHE="$STAMPS" MUX_SHARE="$HERE/share" MUX_DIR="$T/conf" \
	"$HERE/libexec/mux-themes" prune >/dev/null 2>&1 \
	|| fail "prune on an empty stamp dir must be a no-op, not an error"
env MUX_CACHE="$T/nothing-here" MUX_SHARE="$HERE/share" MUX_DIR="$T/conf" \
	"$HERE/libexec/mux-themes" prune >/dev/null 2>&1 \
	|| fail "prune on a MISSING stamp dir must be a no-op, not an error"

# --- IT TOUCHES NOTHING BUT STAMPS ------------------------------------
# $MUX_CACHE also holds the discovery map and in-progress profile edits. A prune
# that matched too broadly would delete a draft someone is still editing.
mkdir -p "$STAMPS/edit"
printf 'a draft\n' >"$STAMPS/edit/proj.profile"
printf 'name\t/path\n' >"$STAMPS/projects.global"
stamp deadthree
env MUX_CACHE="$STAMPS" MUX_SHARE="$HERE/share" MUX_DIR="$T/conf" \
	"$HERE/libexec/mux-themes" prune >/dev/null 2>&1 || true
[ -f "$STAMPS/edit/proj.profile" ] \
	|| fail "the prune deleted an in-progress profile EDIT. Those are
unreconstructible work, and they live in the same directory."
[ -f "$STAMPS/projects.global" ] \
	|| fail "the prune deleted the discovery map"
have deadthree && fail "the dead stamp survived while siblings were at risk"

pass
