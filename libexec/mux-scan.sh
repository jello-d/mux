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
# PER PARTITION, keyed like the agent-state dir, the theme stamps and the
# session set: a scan run in one partition cannot see another's trees, so a
# single shared map would silently conclude those projects do not exist.

# Roots come from the resolved context ($MUX_CFG_scan: repeatable `scan PATH
# [DEPTH]` keys in a .partition or .context file). There is NO built-in
# fallback: the built-in defaults carry behaviour only, never a location, so a
# partition nobody configured gets no roots and therefore no map -- which is
# how a missing context file makes itself visible rather than silently
# indexing somebody else's tree.

# The cache for THIS context. $1 is the socket key (the caller's resolved
# context), defaulting to the ambient one.
mux_scan_file() {       # [partition]
	_sk=${1:-${MUX_CTX_PARTITION:-global}}
	printf '%s/projects.%s' \
		"$(mux_cache_dir)" "$_sk"
}

# The configured roots, as `PATH DEPTH` lines.
mux_scan_roots() {
	[ -n "${MUX_CFG_scan:-}" ] || return 0
	printf '%s\n' "$MUX_CFG_scan" | while read -r _p _d; do
		[ -n "$_p" ] || continue
		printf '%s %s\n' "$(mux_expand_tilde "$_p")" "${_d:-3}"
	done
}

# mux_scan_ignored PATH -> true when PATH matches an `ignore` pattern from the
# resolved context ($MUX_CFG_ignore: repeatable `ignore PATTERN` keys, merged
# exactly like `scan`).
#
# Two matching rules, and only two:
#   - a pattern CONTAINING a slash is a glob against the whole absolute path
#     (`*/athena-repos/*`), for pruning one specific region of a tree;
#   - a pattern with NO slash is matched against each path COMPONENT, so
#     `ignore node_modules` and `ignore vendor` mean the obvious thing rather
#     than silently matching nothing, which is the footgun a whole-path-only
#     rule would ship with.
#
# DISCOVERY ONLY. An explicit `mux go ~/some/ignored/repo` still works: a path
# you typed is evidence, and ignore governs what mux VOLUNTEERS, never what you
# can ask for by name. Ignoring a path you then hand over verbatim would be mux
# arguing with you.
_mux_scan_pat_hit() {   # <abs path> <pattern> -- one pattern, both rules
	# $2 is UNQUOTED on purpose in the two inner cases: it is a glob the
	# user wrote (`*/vendor/*`) and must be matched as one. Quoting it, as
	# SC2254 asks, would make every ignore pattern a literal string and
	# silently match nothing.
	case $2 in
	*/*)
			# shellcheck disable=SC2254
		case $1 in $2) return 0 ;; esac ;;
	*)
		_rest=$1
		while [ -n "$_rest" ]; do
			# shellcheck disable=SC2254
			case ${_rest##*/} in $2) return 0 ;; esac
			case $_rest in
			*/*) _rest=${_rest%/*} ;;
			*)   _rest= ;;
			esac
		done ;;
	esac
	return 1
}

mux_scan_ignored() {    # <abs path>
	[ -n "${MUX_CFG_ignore:-}" ] || return 1
	# Fed by a here-doc, NOT a pipe: a `while` behind a pipe runs in a
	# subshell, where `return` cannot answer for this function and the
	# loop's own status is 0 whether or not anything matched. Same shape
	# _mux_ctx_merge uses to read a settings file.
	while read -r _pat; do
		[ -n "$_pat" ] || continue
		_mux_scan_pat_hit "$1" "$_pat" && return 0
	done <<EOF
$MUX_CFG_ignore
EOF
	return 1
}

# Drop maps for partitions that no longer exist.
#
# Same shape as the palette-stamp prune and the same reasoning: mux made the
# file, mux should clear it, and a directory that only grows is one nobody will
# ever audit. `projects.default` sat on manifold for weeks after the partition
# it indexed stopped existing.
#
# THE ORACLE IS mux_ctx_partitions, which already answers "which partitions mux
# knows of" -- anything with a .partition file, plus the one we are in. A map
# outside that set indexes a namespace that cannot be reached.
#
# ONE GUARD, AND AN EMPTY ANSWER IS NOT AN ANSWER. This lib is sourced by three
# programs that each happen to source mux-context.sh too, but "happens to" is
# not a contract -- so an absent oracle, or one that answers nothing, must mean
# DO NOTHING. The alternative is reading an empty list as "no partition exists"
# and deleting every map on the box.
#
# There was a `command -v mux_ctx_partitions` check here as well, and mutation
# testing showed it could not be killed: with it gone the oracle is simply not
# found, the answer is empty, and the check below catches it anyway. Two guards
# for one condition means neither can be tested, so the redundant one went. Its
# only effect was hiding a "not found" on stderr, which in the case it covers is
# information rather than noise.
#
# Safe even when wrong, which is the licence for doing this automatically: every
# file it can touch is regenerable by definition.
mux_scan_prune() {
	_spd=$(mux_cache_dir)
	[ -d "$_spd" ] || return 0
	_spk=$(mux_ctx_partitions 2>/dev/null | tr '\n' ' ')
	[ -n "$_spk" ] || return 0
	for _spf in "$_spd"/projects.*; do
		[ -e "$_spf" ] || continue
		_spn=${_spf##*/projects.}
		[ -n "$_spn" ] || continue
		case " $_spk " in
		*" $_spn "*) ;;
		*) rm -f "$_spf" ;;
		esac
	done
	return 0
}

# mux_scan_build [socket key] [ignored-log] -> rescan every root and REPLACE the
# cache. Writes via a temp and moves, so a concurrent reader never sees a
# half-written map. Echoes nothing; the caller reports.
#
# IGNORED-LOG, if given, collects every path dropped by an `ignore` pattern, so
# `mux scan` can report the count and call out a pattern that matched NOTHING.
# Silent discarding is how a typo'd pattern looks exactly like a correct one.
mux_scan_build() {      # [socket key] [ignored-log]
	_sf=$(mux_scan_file "${1:-}")
	mkdir -p "$(dirname "$_sf")"
	# Before the rebuild, so a prune that goes wrong cannot take the map this
	# call is about to write.
	mux_scan_prune
	_st=$_sf.tmp.$$
	_ilog=${2:-}
	[ -n "$_ilog" ] && : 2>/dev/null >"$_ilog" || _ilog=/dev/null
	: >"$_st"
	mux_scan_roots | while read -r _root _depth; do
		[ -d "$_root" ] || continue
		# A repo is a directory holding .git. -prune stops the walk there,
		# so a repo's own history and any vendored checkouts below it do
		# not get traversed.
		find "$_root" -maxdepth "$_depth" -name .git -prune 2>/dev/null \
		| while IFS= read -r _g; do
			_p=${_g%/.git}
			# Filtered here rather than pruned in find: building
			# find's arguments from arbitrary patterns invites
			# quoting bugs, and the walk is depth-bounded anyway.
			if mux_scan_ignored "$_p"; then
				printf '%s\n' "$_p" >>"$_ilog"
				continue
			fi
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
