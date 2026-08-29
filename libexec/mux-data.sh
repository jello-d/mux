#!/bin/sh
# mux-data.sh - the ONE $MUX_DIR-over-$MUX_SHARE resolver for mux's package
# data: layouts, shapes, colour themes, agent profiles. Sourced (functions
# only); source it, do not run it.
#
# The documented rule, in one place: a READ checks the user overlay $MUX_DIR
# first and falls back to the shipped defaults in $MUX_SHARE, so `include
# shapes/code` finds the packaged shape while a layout, theme or agent profile
# you drop in $MUX_DIR wins over its shipped twin of the same name. WRITES
# (`mux new`, `mux save`, `mux theme -p`) always go to $MUX_DIR and are not
# this file's business.
#
# It exists because the rule used to be open-coded per call site, and the sites
# had drifted apart: `help colors` and `help agents` read only $MUX_DIR (so
# both printed an empty body on a shipped install), while the theme validators,
# the `mux --help` listing and mux-themes read only $MUX_SHARE (so the theme
# overlay the README and man page both promise did not exist at all). One
# resolver, so the sites cannot disagree again.
#
# KIND is a subdirectory of the data root -- `themes`, `agents`, `shapes` -- or
# EMPTY for the root itself, where layouts live. EXT is the file extension
# including its dot, or empty for an extensionless file (themes/defaults).

# mux_data_find KIND NAME EXT -> the winning path for NAME, or nothing.
mux_data_find() {
	_dk=${1:+/$1}
	if   [ -f "$MUX_DIR$_dk/$2$3" ];   then printf '%s' "$MUX_DIR$_dk/$2$3"
	elif [ -f "$MUX_SHARE$_dk/$2$3" ]; then printf '%s' "$MUX_SHARE$_dk/$2$3"
	fi
}

# mux_data_stems KIND EXT -> every NAME available for KIND, one per line,
# sorted and deduped: the shipped set plus whatever the overlay adds. An
# overlay file of the same name is the SAME name, not a second entry, so a
# listing never shows a name twice because it was overridden.
mux_data_stems() {
	_dk=${1:+/$1}
	for _dd in "$MUX_SHARE$_dk" "$MUX_DIR$_dk"; do
		[ -d "$_dd" ] || continue
		for _df in "$_dd"/*"$2"; do
			[ -e "$_df" ] || continue
			_db=${_df##*/}
			printf '%s\n' "${_db%"$2"}"
		done
	done | LC_ALL=C sort -u
}

# mux_data_files KIND EXT -> the WINNING path for every available NAME, one per
# line, in mux_data_stems order. The listing form: iterate this and every entry
# is already the file the rest of mux would read for that name.
mux_data_files() {
	mux_data_stems "$1" "$2" | while IFS= read -r _ds; do
		_dp=$(mux_data_find "$1" "$_ds" "$2")
		[ -n "$_dp" ] && printf '%s\n' "$_dp"
	done
	return 0
}
