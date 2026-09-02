#!/bin/sh
# mux-sessions.sh - the SESSION SET: which sessions this partition had, so a
# reboot is followed by `mux restore` and not by rebuilding five sessions by
# hand. Sourced (functions only).
#
# STATE, not config. It lives under $MUX_CACHE, never in $MUX_DIR and never in
# git: which sessions are up is per-machine and transient. But it must outlive a
# reboot, so $MUX_CACHE (under ~/.cache) rather than anything in /tmp.
#
# Recorded AUTOMATICALLY, because the scenario is "the machine rebooted" --
# exactly the moment you did not think to save. Adding a session records it,
# killing one removes it, `kill --all` clears the set. There is deliberately no
# save verb: `mux save` already means "capture this session's shape into a
# profile", and a second meaning would be one too many.
#
# ADDITIVE on create and SUBTRACTIVE on kill, NOT a snapshot of what is live. A
# snapshot would be clobbered by the first `mux go` after a reboot -- at which
# point exactly one session is up -- destroying the very record being restored.
#
# Each line is NAME<TAB>ROOT. The root is not optional: the common session is a
# bare `mux go` in a directory, which has no profile and no map entry, so the
# name alone is not enough to rebuild it. Recording where it lived makes the set
# an evidence source in its own right -- `mux go <name>` can resolve through it
# exactly as it resolves through a profile or the discovery map.
#
# Insertion-ordered, so a restore rebuilds in the order you first opened them
# and lands you on the oldest, which is usually the one you think of as primary.
#
# Keyed on the PARTITION (today: the tmux socket, which a partition owns), so
# each isolated namespace restores only its own.

# The set file for a partition. KEY defaults to the ambient socket, matching
# how the theme stamp and the agent-state dir are keyed.
mux_sess_file() {       # [key]
	_sk=${1:-}
	if [ -z "$_sk" ]; then
		_sk=default
		[ -n "${TMUX:-}" ] && { _sk=${TMUX%%,*}; _sk=${_sk##*/}; }
	fi
	printf '%s/sessions.%s' \
		"${MUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mux}" "$_sk"
}

# mux_sess_list [key] -> every recorded name, one per line, insertion order.
mux_sess_list() {       # [key]
	_sf=$(mux_sess_file "${1:-}")
	[ -f "$_sf" ] || return 0
	cut -f1 "$_sf" 2>/dev/null | grep . || true
}

# mux_sess_root NAME [key] -> where that session lived, or empty.
mux_sess_root() {       # <name> [key]
	_sf=$(mux_sess_file "${2:-}")
	[ -f "$_sf" ] || return 0
	awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$_sf"
}

# mux_sess_add NAME ROOT [key] -> record NAME if it is not already there.
# Idempotent, so recording on every attach (not just on build) heals a set that
# predates this feature or a session someone made with raw tmux.
mux_sess_add() {        # <name> <root> [key]
	[ -n "$1" ] || return 0
	_sf=$(mux_sess_file "${3:-}")
	mkdir -p "$(dirname "$_sf")" 2>/dev/null || return 0
	cut -f1 "$_sf" 2>/dev/null | grep -qxF "$1" && return 0
	printf '%s\t%s\n' "$1" "$2" >>"$_sf" 2>/dev/null || true
	return 0
}

# mux_sess_drop NAME [key] -> forget NAME. Via a temp and a move, so an
# interrupted write cannot truncate the set.
mux_sess_drop() {       # <name> [key]
	[ -n "$1" ] || return 0
	_sf=$(mux_sess_file "${2:-}")
	[ -f "$_sf" ] || return 0
	_st=$_sf.tmp.$$
	awk -F'\t' -v n="$1" '$1!=n' "$_sf" >"$_st" 2>/dev/null
	mv -f "$_st" "$_sf" 2>/dev/null || rm -f "$_st"
	return 0
}

# mux_sess_clear [key] -> forget the whole set (kill --all).
mux_sess_clear() {      # [key]
	rm -f "$(mux_sess_file "${1:-}")" 2>/dev/null || true
	return 0
}
