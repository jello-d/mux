#!/bin/sh
# mux-agent-state.sh - shared reader for per-pane agent state (see
# agent-state-emit). Sourced by agent-state-render (the status strip) AND by the
# mux front end (the session picker and `mux ls`), so the state ranking and the
# state GLYPHS live in ONE place, so the bar and the picker cannot drift apart.
# Functions and glyph constants only; source it, do not run it.
#
# State lives in per-pane files under $XDG_RUNTIME_DIR/agent-state/<ns>, a line
# each: "state session window pane epoch notif-id" (see agent-state-emit). The
# namespace <ns> is the tmux socket basename, so a work bar never shows personal
# agents and vice versa.

# Width-2 glyphs, so a caller that aligns columns (the strip) holds line. This
# is the single source of the state->glyph mapping; the strip's colour STYLES
# stay in agent-state-render, which owns the bar's look.
MUX_GLYPH_BLOCKED='⚠️' ; MUX_GLYPH_WORKING='🧠' ; MUX_GLYPH_IDLE='✅'
MUX_GLYPH_NONE='⚫'    ; MUX_GLYPH_UNKNOWN='❓'

# mux_agent_dir [NS] -> the namespaced state directory. NS is $1 if given, else
# the current tmux socket basename (from $TMUX), else 'default'. Callers outside
# tmux (the picker on a bare shell) pass the socket they resolved.
mux_agent_dir() {
	_rt=${XDG_RUNTIME_DIR:-/tmp/user-$(id -u)}
	_ns=${1:-}
	if [ -z "$_ns" ]; then
		_ns=default
		[ -n "${TMUX:-}" ] && { _ns=${TMUX%%,*}; _ns=${_ns##*/}; }
	fi
	printf '%s/agent-state/%s' "$_rt" "$_ns"
}

# Numeric urgency of a state, so the worst live agent in a session wins.
mux_agent_rank() {
	case $1 in
	blocked) echo 3 ;;
	working) echo 2 ;;
	idle)    echo 1 ;;
	*)       echo 0 ;;
	esac
}

# mux_agent_state DIR SESSION -> "STATE EPOCH": the most-urgent live agent state
# for SESSION (blocked > working > idle) and the epoch that state began, or a
# lone space when the session has no tracked agent. A session may hold several
# agent panes; the worst one wins (and carries its epoch), so nothing is hidden.
mux_agent_state() {
	_asdir=$1 _assess=$2
	_best= _bestep= _br=-1
	[ -d "$_asdir" ] || { printf ' '; return; }
	for _f in "$_asdir"/*; do
		[ -e "$_f" ] || continue
		read -r _st _ss _w _p _e _nid <"$_f" || continue
		[ "$_ss" = "$_assess" ] || continue
		_r=$(mux_agent_rank "$_st")
		[ "$_r" -gt "$_br" ] && { _br=$_r; _best=$_st; _bestep=$_e; }
	done
	printf '%s %s' "$_best" "$_bestep"
}

# mux_agent_glyph STATE -> the width-2 glyph for a state word ('' -> none).
mux_agent_glyph() {
	case $1 in
	blocked) printf '%s' "$MUX_GLYPH_BLOCKED" ;;
	working) printf '%s' "$MUX_GLYPH_WORKING" ;;
	idle)    printf '%s' "$MUX_GLYPH_IDLE" ;;
	'')      printf '%s' "$MUX_GLYPH_NONE" ;;
	*)       printf '%s' "$MUX_GLYPH_UNKNOWN" ;;
	esac
}

# mux_agent_state_glyph DIR SESSION -> just the state glyph for SESSION, for
# callers that want the glyph and not the epoch (the picker and `mux ls`).
mux_agent_state_glyph() {
	_sg=$(mux_agent_state "$1" "$2")
	mux_agent_glyph "${_sg%% *}"
}
