#!/bin/sh
# mux-paths.sh - WHERE MUX KEEPS THINGS. One place, because the answer was
# open-coded in five. Sourced (functions only); source it, do not run it.
#
# Three homes, and the line between them is a question with a yes/no answer:
# DOES IT REBUILD?
#
#   $MUX_DIR    your config. Authored, and mux writes here too (`mux save`,
#               `mux edit`, `mux theme`). Resolved in mux-data.sh, not here.
#
#   $MUX_CACHE  YES, it rebuilds. Palette stamps and the project discovery map:
#               both regenerate on demand from what they summarise, so losing
#               one costs a moment of work and nothing else. ~/.cache is by
#               definition the directory anything may delete to reclaim space,
#               and that is fine for these.
#
#   $MUX_STATE  NO, it does not rebuild. The session set accumulates one
#               `mux go` at a time; an unsaved profile draft is work you typed.
#               Nothing can reconstruct either from anything else, so a cache
#               clear must not be able to take them.
#
# THAT TEST IS THE WHOLE DESIGN, and it was got wrong twice. The session set
# sat in $MUX_CACHE until 0.38 and the edit draft until 0.39, both on the
# reasoning that they were "transient" -- true of the FACT each records, and
# irrelevant to whether the file can be rebuilt. The cost shows up much later:
# a cache clear, then a reboot, then a `mux resume` that finds nothing -- at the
# one moment the answer cannot be reconstructed from anywhere.
#
# So when adding a new file, ask only whether mux could regenerate it. If not,
# it belongs under mux_state_path and gets the adoption below for free.

# Regenerable state. $MUX_CACHE overrides it so an integrator can relocate it.
mux_cache_dir() {
	printf '%s' "${MUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mux}"
}

# Durable, unreconstructible state. $XDG_STATE_HOME is the standard home for
# exactly this category: keep it across restarts, but it is not precious enough
# to be user DATA.
mux_state_dir() {
	printf '%s' "${MUX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/mux}"
}

# mux_state_path REL -> the state path for REL, ADOPTING a pre-0.38 copy left in
# the cache. Works for a file or a directory.
#
# THE ADOPTION IS WHY THIS IS A FUNCTION AND NOT A VARIABLE. An upgrade lands
# while things are already recorded, and the next thing to read them may be the
# `mux resume` after a reboot -- so a file left behind in the old location is a
# file lost at the one moment it mattered. Doing it on first touch means there
# is no verb to remember and no window in which it has not happened yet.
#
# NEVER CLOBBERS. If the state copy already exists the cache copy is left where
# it is and ignored: an upgrade followed by real use would otherwise lose
# everything recorded in between, which is worse than the stale file it avoids.
#
# Best effort. A failed move must not break the caller, which then simply sees
# nothing rather than an error, and the old copy is left intact so a later run
# can still adopt it.
mux_state_path() {      # <relative path>
	_mpd=$(mux_state_dir)
	_mpn=$_mpd/$1
	_mpo=$(mux_cache_dir)/$1
	if [ ! -e "$_mpn" ] && [ -e "$_mpo" ]; then
		if mkdir -p "$(dirname "$_mpn")" 2>/dev/null; then
			mv -f "$_mpo" "$_mpn" 2>/dev/null || true
		fi
	fi
	printf '%s' "$_mpn"
}
