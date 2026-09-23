#!/bin/sh
# mux-sessions.sh - the SESSION SET: which sessions this partition had, so a
# reboot is followed by `mux resume` and not by rebuilding five sessions by
# hand. Sourced (functions only).
#
# STATE, not config, and not CACHE either. Never in $MUX_DIR and never in git:
# which sessions are up is per-machine. But it must outlive a reboot, so not
# /tmp -- and it must outlive a CACHE CLEAR, which is the part that was wrong.
#
# It lived under $MUX_CACHE (~/.cache/mux) until 0.38. The comment here reasoned
# about cache versus /tmp and never about cache versus state, and ~/.cache is by
# definition the directory anything may delete to reclaim space. NOTHING
# REBUILDS THIS FILE: the set is accumulated one `mux go` at a time, so clearing
# the cache silently destroyed the answer to "what was I working on", and the
# only moment you would notice is the `mux resume` after a reboot -- exactly
# when you cannot reconstruct it.
#
# $MUX_STATE ($XDG_STATE_HOME/mux, i.e. ~/.local/state/mux) is the XDG home for
# precisely this: durable, unreconstructible, not precious enough to be data.
# The palette stamps and the discovery map stay in $MUX_CACHE, correctly -- both
# regenerate on demand, which is what makes them a cache.
#
# Recorded AUTOMATICALLY, because the scenario is "the machine rebooted" --
# exactly the moment you did not think to save. Adding a session records it,
# killing one removes it, `kill --all` clears the set. There is deliberately no
# save verb: `mux save` already means "capture this session's shape into a
# profile", and a second meaning would be one too many.
#
# ADDITIVE on create and SUBTRACTIVE on kill, NOT a snapshot of what is live. A
# snapshot would be clobbered by the first `mux go` after a reboot -- at which
# point exactly one session is up -- destroying the very record being rebuilt.
#
# Each line is NAME<TAB>ROOT. The root is not optional: the common session is a
# bare `mux go` in a directory, which has no profile and no map entry, so the
# name alone is not enough to rebuild it. Recording where it lived makes the set
# an evidence source in its own right -- `mux go <name>` can resolve through it
# exactly as it resolves through a profile or the discovery map.
#
# Insertion-ordered, so a resume rebuilds in the order you first opened them
# and lands you on the oldest, which is usually the one you think of as primary.
#
# Keyed on the PARTITION, so each isolated namespace resumes only its own.

# The set file for a partition. KEY defaults to the ambient socket, matching
# how the theme stamp and the agent-state dir are keyed.
#
# MIGRATES ON FIRST TOUCH, and it has to happen here rather than in a verb
# somebody has to remember to run. The upgrade lands while sessions are already
# recorded, and the very next thing that reads this file is likely the
# `mux resume` after a reboot -- so a set left behind in the old location is a
# set lost at the one moment it mattered. The move is a rename, idempotent, and
# silent when there is nothing to move.
mux_sess_file() {       # [partition]
	_sk=${1:-${MUX_CTX_PARTITION:-global}}
	mux_state_path "sessions.$_sk"
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

# mux_sess_has NAME [key] -> is NAME recorded? MEMBERSHIP, which is not the
# same question as mux_sess_root: a record may legitimately carry an EMPTY root
# (tmux could not report session_path when it was added), so a non-empty root
# is not a membership test and using one silently misses those entries.
mux_sess_has() {        # <name> [key]
	[ -n "${1:-}" ] || return 1
	_sf=$(mux_sess_file "${2:-}")
	[ -f "$_sf" ] || return 1
	cut -f1 "$_sf" 2>/dev/null | grep -qxF "$1"
}

# mux_sess_add NAME ROOT [key] -> record NAME if it is not already there.
# Idempotent, so recording on every attach (not just on build) heals a set that
# predates this feature or a session someone made with raw tmux.
mux_sess_add() {        # <name> <root> [key]
	[ -n "$1" ] || return 0
	_sf=$(mux_sess_file "${3:-}")
	mkdir -p "$(dirname "$_sf")" 2>/dev/null || return 0
	mux_sess_has "$1" "${3:-}" && return 0
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
