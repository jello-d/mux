#!/bin/sh
# test/mux-data.t - the shared package-data resolver, mux_data_* in
# libexec/mux-data.sh: the ONE $MUX_DIR-over-$MUX_SHARE rule for layouts,
# shapes, themes and agent profiles. Pure path logic against a scratch pair of
# data roots; nothing on the box is touched.
set -eu
_name=mux-data
. "$(dirname "$0")/lib.sh"
. "$HERE/libexec/mux-data.sh"

MUX_SHARE=$T/share
MUX_DIR=$T/dir
mkdir -p "$MUX_SHARE/themes" "$MUX_SHARE/agents" "$MUX_SHARE/shapes" \
	"$MUX_DIR/themes"
# shipped: two themes, one agent, one shape, the default layout, a defaults file
: >"$MUX_SHARE/themes/purple.theme"
: >"$MUX_SHARE/themes/cyan.theme"
: >"$MUX_SHARE/themes/defaults"
: >"$MUX_SHARE/agents/claude.agent"
: >"$MUX_SHARE/shapes/code.layout"
: >"$MUX_SHARE/default.layout"
# overlay: one theme that SHADOWS a shipped name, one that is overlay-only,
# and one layout of its own.
: >"$MUX_DIR/themes/purple.theme"
: >"$MUX_DIR/themes/neon.theme"
: >"$MUX_DIR/api.layout"

eq() {  # LABEL GOT WANT
	[ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"
}

# --- mux_data_find: the overlay wins, the shipped copy is the fallback ------
eq overlay-wins   "$(mux_data_find themes purple .theme)" \
                  "$MUX_DIR/themes/purple.theme"
eq shipped-fallback "$(mux_data_find themes cyan .theme)" \
                  "$MUX_SHARE/themes/cyan.theme"
eq overlay-only   "$(mux_data_find themes neon .theme)" \
                  "$MUX_DIR/themes/neon.theme"
eq missing-empty  "$(mux_data_find themes nosuch .theme)" ""

# An EMPTY kind is the data root, where layouts live -- no doubled slash, and
# the shipped default.layout resolves (a fresh install's `mux go` depends on
# it) while a user layout of its own name still wins.
eq layout-shipped "$(mux_data_find '' default .layout)" \
                  "$MUX_SHARE/default.layout"
eq layout-overlay "$(mux_data_find '' api .layout)" "$MUX_DIR/api.layout"
# A nested kind, as `include shapes/code` reaches it.
eq shape-shipped  "$(mux_data_find shapes code .layout)" \
                  "$MUX_SHARE/shapes/code.layout"
# An EMPTY ext, for the extensionless themes/defaults file.
eq noext          "$(mux_data_find themes defaults '')" \
                  "$MUX_SHARE/themes/defaults"

# --- mux_data_stems: the union, sorted, with no name listed twice -----------
# purple exists in BOTH roots and must appear ONCE -- an override is the same
# name, not a second theme.
eq stems-union "$(mux_data_stems themes .theme | tr '\n' ' ')" \
               "cyan neon purple "
eq stems-agents "$(mux_data_stems agents .agent | tr '\n' ' ')" "claude "
eq stems-layouts "$(mux_data_stems '' .layout | tr '\n' ' ')" "api default "
# defaults has no .theme extension, so it is not a theme NAME.
case "$(mux_data_stems themes .theme)" in
*defaults*) fail "stems: the extensionless defaults file listed as a theme" ;;
esac

# --- mux_data_files: every stem resolved to the file mux would read ---------
eq files-resolved "$(mux_data_files themes .theme | tr '\n' ' ')" \
	"$MUX_SHARE/themes/cyan.theme \
$MUX_DIR/themes/neon.theme $MUX_DIR/themes/purple.theme "

# --- empty roots ------------------------------------------------------------
# No overlay at all: the shipped set, unchanged (the shipped-install case that
# used to print an empty `mux help colors`).
MUX_DIR=$T/nonexistent
eq no-overlay-stems "$(mux_data_stems themes .theme | tr '\n' ' ')" \
                    "cyan purple "
eq no-overlay-find  "$(mux_data_find themes purple .theme)" \
                    "$MUX_SHARE/themes/purple.theme"
# Neither root present: empty, not an error (callers report the miss).
MUX_SHARE=$T/nonexistent
eq no-roots-stems "$(mux_data_stems themes .theme)" ""
eq no-roots-find  "$(mux_data_find themes purple .theme)" ""
eq no-roots-files "$(mux_data_files themes .theme)" ""

pass
