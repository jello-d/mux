#!/bin/sh
# mux-profiles.sh - the profile TABLE: $MUX_DIR/profiles, one line per session
# that deviates from what mux would derive. Sourced (functions only).
#
#   # NAME      key=value ...
#   api         theme=cyan
#   kg          root=~/src/ManifestOS/apps/knowledge-store
#   jellotron   layout=logs
#   waybar      root=~/src/tackup/build/overlays/waybar theme=slate
#
# Column one is the session NAME, and it is the key: a repo that moves keeps its
# row. The rest are the SAME keys a breakout profile uses (root, theme, agent,
# notify, layout), so a row and a $MUX_DIR/profiles.d/<name>.profile say the
# same things and promotion between them is mechanical.
#
# The only deviation from the breakout syntax is `=`, which is what lets several
# pairs share one line. It also means a VALUE CANNOT CONTAIN WHITESPACE. That is
# deliberate rather than a limitation to work around: a root with a space in it
# is exactly the case that should live in a breakout file, where a directive is
# `key rest-of-line` and spaces are free.
#
# Rows exist only for deviations. Everything else is derived -- name from the
# directory, root from the scan map, theme from the name's hash, layout from
# `default`, agent from `claude` -- so most projects need no row at all.

# Expand a leading tilde without eval. Here rather than in the front end because
# every root comparison below needs it, and two copies would drift.
mux_expand_tilde() {    # <path>
	case $1 in
	"~")   printf '%s' "$HOME" ;;
	"~/"*) printf '%s' "$HOME/${1#\~/}" ;;
	*)     printf '%s' "$1" ;;
	esac
}

# Fold $HOME back to ~, so a row written today travels to another machine.
mux_fold_tilde() {      # <path>
	case $1 in
	"$HOME")   printf '~' ;;
	"$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
	*)         printf '%s' "$1" ;;
	esac
}

# The table file. Not created until something needs to write one.
mux_prof_file() {
	printf '%s/profiles' "$MUX_DIR"
}

# Every row, comments and blanks stripped. The shared cleaner is not used here:
# it strips ` #` inline, and a value could legitimately end in one.
_mux_prof_rows() {
	_pf=$(mux_prof_file)
	[ -f "$_pf" ] || return 0
	sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$_pf"
}

# mux_prof_names -> every name in the table, one per line.
mux_prof_names() {
	_mux_prof_rows | awk '{print $1}'
}

# mux_prof_pairs NAME -> that row's key=value pairs, space separated, or empty.
mux_prof_pairs() {      # <name>
	_mux_prof_rows | awk -v n="$1" '$1==n{$1=""; sub(/^ +/,""); print; exit}'
}

# mux_prof_get NAME KEY -> one value, or empty.
mux_prof_get() {        # <name> <key>
	for _p in $(mux_prof_pairs "$1"); do
		case $_p in "$2"=*) printf '%s' "${_p#*=}"; return 0 ;; esac
	done
}

# mux_prof_has NAME -> true when the table carries a row for NAME.
mux_prof_has() {        # <name>
	mux_prof_names | grep -qxF "$1"
}

# mux_prof_by_root DIR -> the name of the row whose `root` IS DIR, or empty.
# EXACT match, after expanding both sides, and no walk up the tree: it exists so
# an alias is authoritative for its own directory (a row binding `BigPicture` to
# a repo must beat deriving `ManifestOS-arch` from that same repo), not to make
# subdirectories resolve, which stays an outlier reached by typing the name.
mux_prof_by_root() {    # <dir>
	_want=$(mux_expand_tilde "$1")
	# Done in awk rather than a shell loop: a `while read` after a pipe runs
	# in a subshell, where an early `return` would leave the loop running.
	_mux_prof_rows | awk -v want="$_want" -v home="$HOME" '
	{
		for (i = 2; i <= NF; i++) {
			if (substr($i, 1, 5) != "root=") continue
			r = substr($i, 6)
			if (r == "~") r = home
			else if (substr(r, 1, 2) == "~/") r = home "/" substr(r, 3)
			if (r == want) { print $1; exit }
		}
	}'
}

# mux_prof_directives NAME -> the row as `key value` lines, i.e. exactly what a
# breakout profile file holds. One parse path downstream, whichever form the
# profile was stored in.
mux_prof_directives() { # <name>
	for _p in $(mux_prof_pairs "$1"); do
		case $_p in
		*=*) printf '%s %s\n' "${_p%%=*}" "${_p#*=}" ;;
		*)   printf 'mux: bad pair in profiles row %s: %s\n' "$1" "$_p" >&2
		     return 1 ;;
		esac
	done
	return 0
}

# mux_prof_set NAME KEY VALUE -> add or update one pair, preserving the rest of
# the row, every other row, and the file's comments. Written to a temp and
# moved, so an interrupted write cannot truncate the table.
mux_prof_set() {        # <name> <key> <value>
	_pf=$(mux_prof_file)
	mkdir -p "$MUX_DIR"
	[ -f "$_pf" ] || {
		printf '# mux profiles: one line per session that deviates from\n' \
			>"$_pf"
		printf '# what mux derives. NAME then key=value pairs; keys are\n' \
			>>"$_pf"
		printf '# root, theme, agent, notify, layout. See mux(1).\n' >>"$_pf"
	}
	_tmp=$_pf.tmp.$$
	awk -v n="$1" -v k="$2" -v v="$3" '
	BEGIN { found = 0 }
	# comments and blanks pass through untouched, so a hand-annotated table
	# survives mux writing to it.
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
	$1 == n {
		pairs = ""; seen = 0
		for (i = 2; i <= NF; i++) {
			split($i, kv, "=")
			if (kv[1] == k) { pairs = pairs " " k "=" v; seen = 1 }
			else pairs = pairs " " $i
		}
		if (!seen) pairs = pairs " " k "=" v
		sub(/^ /, "", pairs)
		printf "%-11s %s\n", n, pairs
		found = 1; next
	}
	{ print }
	END { if (!found) printf "%-11s %s=%s\n", n, k, v }
	' "$_pf" >"$_tmp" || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$_pf"
}

# mux_prof_replace NAME PAIRS -> set NAME's row to exactly PAIRS (space
# separated `key=value`), IN PLACE. Distinct from a sequence of mux_prof_set
# calls in two ways that matter after an edit: a key the editor DELETED
# disappears rather than surviving, and the row keeps its position in the file
# instead of moving to the end and churning the diff. An empty PAIRS drops the
# row, which is the right answer when nothing about the session deviates any
# more.
mux_prof_replace() {    # <name> <pairs>
	[ -n "$2" ] || { mux_prof_drop "$1"; return 0; }
	_pf=$(mux_prof_file)
	mkdir -p "$MUX_DIR"
	[ -f "$_pf" ] || : >"$_pf"
	_tmp=$_pf.tmp.$$
	awk -v n="$1" -v p="$2" '
	BEGIN { found = 0 }
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
	$1 == n { printf "%-11s %s\n", n, p; found = 1; next }
	{ print }
	END { if (!found) printf "%-11s %s\n", n, p }
	' "$_pf" >"$_tmp" || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$_pf"
}

# mux_prof_drop NAME -> remove NAME's row entirely (used when a row is promoted
# to a breakout file, so a name never lives in both places).
mux_prof_drop() {       # <name>
	_pf=$(mux_prof_file)
	[ -f "$_pf" ] || return 0
	_tmp=$_pf.tmp.$$
	awk -v n="$1" '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
	$1 == n { next }
	{ print }
	' "$_pf" >"$_tmp" || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$_pf"
}
