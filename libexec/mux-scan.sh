#!/bin/sh
# mux-scan.sh - project DISCOVERY: a cached map from a session name to the
# repository it lives in, so `mux go <name>` reaches a project you have never
# configured and never have to cd to first. Sourced (functions only).
#
# The map is a CACHE, not config. It holds only derived facts, it is rewritten
# wholesale, and deleting it loses nothing -- which is what makes it safe to
# regenerate without any merge against things you have edited. Everything you
# decided lives in the profile table (see mux-profiles.sh); the two are never
# the same file.
#
# Rebuilt on exactly three triggers, and never by a timer:
#   - `mux scan`, explicitly;
#   - the cache being absent, on first use;
#   - a lookup MISS, or a hit whose path is no longer a directory.
# Between the last two the map corrects itself whether an entry appeared,
# moved, or vanished, so there is no staleness clock to tune. A periodic
# rebuild could only help in cases where the staleness had no observable
# effect, which is why mux stays daemon-free.
#
# PER CONTEXT, keyed like the agent-state dir and the theme stamps: a scan run
# on one side of a context boundary cannot see the other side's trees, so a
# single shared map would silently conclude those projects do not exist.

# Where the scan roots are declared: $MUX_DIR/scan, one `PATH [DEPTH]` per line
# (DEPTH defaults to 3). With no such file, ~/src is used when it exists, which
# `mux scan` always reports so the default is visible rather than magic.
mux_scan_conf() {
	printf '%s/scan' "$MUX_DIR"
}

# The cache for THIS context. $1 is the socket key (the caller's resolved
# context), defaulting to the ambient one.
mux_scan_file() {       # [socket key]
	_sk=${1:-}
	if [ -z "$_sk" ]; then
		_sk=default
		[ -n "${TMUX:-}" ] && { _sk=${TMUX%%,*}; _sk=${_sk##*/}; }
	fi
	printf '%s/projects.%s' \
		"${MUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mux}" "$_sk"
}

# The configured roots, as `PATH DEPTH` lines.
mux_scan_roots() {
	_sc=$(mux_scan_conf)
	if [ -f "$_sc" ]; then
		sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
			"$_sc" \
		| while read -r _p _d; do
			printf '%s %s\n' "$(mux_expand_tilde "$_p")" "${_d:-3}"
		done
	elif [ -d "$HOME/src" ]; then
		printf '%s 3\n' "$HOME/src"
	fi
}

# mux_scan_build [socket key] -> rescan every root and REPLACE the cache. Writes
# via a temp and moves, so a concurrent reader never sees a half-written map.
# Echoes nothing; the caller reports.
mux_scan_build() {      # [socket key]
	_sf=$(mux_scan_file "${1:-}")
	mkdir -p "$(dirname "$_sf")"
	_st=$_sf.tmp.$$
	: >"$_st"
	mux_scan_roots | while read -r _root _depth; do
		[ -d "$_root" ] || continue
		# A repo is a directory holding .git. -prune stops the walk there,
		# so a repo's own history and any vendored checkouts below it do
		# not get traversed.
		find "$_root" -maxdepth "$_depth" -name .git -prune 2>/dev/null \
		| while IFS= read -r _g; do
			_p=${_g%/.git}
			printf '%s\t%s\n' "${_p##*/}" "$_p"
		done
	done >>"$_st"
	LC_ALL=C sort -u "$_st" -o "$_st" 2>/dev/null || true
	mv -f "$_st" "$_sf"
}

# mux_scan_lookup NAME [socket key] -> every path mapped to NAME, one per line.
# More than one means two repos share a basename, which the caller reports
# rather than guessing between.
mux_scan_lookup() {     # <name> [socket key]
	_sf=$(mux_scan_file "${2:-}")
	[ -f "$_sf" ] || return 0
	awk -F'\t' -v n="$1" '$1==n{print $2}' "$_sf"
}

# mux_scan_names [socket key] -> every known name, for did-you-mean and help.
mux_scan_names() {      # [socket key]
	_sf=$(mux_scan_file "${1:-}")
	[ -f "$_sf" ] || return 0
	cut -f1 "$_sf"
}

# mux_scan_near NAME [socket key] -> names worth suggesting for a miss: within
# an edit distance of 2, or containing / contained by NAME. Suggestions are what
# make refusing an unknown name palatable rather than merely strict, so this is
# worth doing properly -- a prefix test misses `alfa` for `alpha`, which is
# exactly the shape of typo it exists to catch. Levenshtein in awk, no
# dependency. Candidates come from both the map and the table, so an alias is
# suggested as readily as a scanned repo.
mux_scan_near() {       # <name> [socket key]
	{ mux_scan_names "${2:-}"; mux_prof_names; } 2>/dev/null \
	| LC_ALL=C sort -u | awk -v n="$1" '
	function lev(a, b,   la, lb, i, j, c, cost, prev, cur) {
		la = length(a); lb = length(b)
		if (la == 0) return lb
		if (lb == 0) return la
		for (j = 0; j <= lb; j++) prev[j] = j
		for (i = 1; i <= la; i++) {
			cur[0] = i
			for (j = 1; j <= lb; j++) {
				cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
				c = prev[j] + 1
				if (cur[j-1] + 1 < c) c = cur[j-1] + 1
				if (prev[j-1] + cost < c) c = prev[j-1] + cost
				cur[j] = c
			}
			for (j = 0; j <= lb; j++) prev[j] = cur[j]
		}
		return prev[lb]
	}
	$0 == n || $0 == "" { next }
	{ if (lev(tolower($0), tolower(n)) <= 2 || index($0, n) || index(n, $0))
		print }
	'
}
