#!/bin/sh
# test/mux-profiles.t - the profile TABLE ($MUX_DIR/profiles): reading rows,
# resolving a name to its keys, finding a name by its root, and writing a pair
# back without disturbing the rest of the file. Pure text logic against a
# scratch $MUX_DIR; nothing on the box is touched.
set -eu
_name=mux-profiles
. "$(dirname "$0")/lib.sh"
. "$HERE/libexec/mux-profiles.sh"

MUX_DIR=$T/conf
mkdir -p "$MUX_DIR"
cat >"$MUX_DIR/profiles" <<EOF
# a comment, and a blank line, both of which must survive a write

api         theme=cyan
kg          root=~/src/knowledge-store
waybar      root=$T/waybar theme=slate layout=logs
EOF

eq() {  # LABEL GOT WANT
	[ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"
}

# --- reading ----------------------------------------------------------------
eq names "$(mux_prof_names | tr '\n' ' ')" "api kg waybar "
eq get-one   "$(mux_prof_get api theme)" "cyan"
eq get-late  "$(mux_prof_get waybar layout)" "logs"
eq get-absent "$(mux_prof_get api root)" ""
eq get-norow "$(mux_prof_get nosuch theme)" ""
mux_prof_has api    || fail "has: api should be present"
mux_prof_has nosuch && fail "has: nosuch should be absent"

# A row converts to the SAME `key value` lines a breakout profile holds, so
# there is one parse path downstream whichever form was used.
eq directives "$(mux_prof_directives waybar | tr '\n' ';')" \
	"root $T/waybar;theme slate;layout logs;"

# --- root -> name, the alias binding ---------------------------------------
# Exact match, so an alias is authoritative for its own directory.
eq by-root "$(mux_prof_by_root "$T/waybar")" "waybar"
# ... including through a ~ in the stored value.
eq by-root-tilde "$(mux_prof_by_root "$HOME/src/knowledge-store")" "kg"
# A SUBDIRECTORY must NOT match: subdirs stay an outlier reached by name, and
# an ancestor walk here is what we deliberately did not build.
eq by-root-subdir "$(mux_prof_by_root "$T/waybar/src")" ""
eq by-root-miss "$(mux_prof_by_root "$T/nowhere")" ""
# A row with no root at all cannot be matched by one.
eq by-root-rootless "$(mux_prof_by_root "")" ""

# --- writing ----------------------------------------------------------------
# Updating an existing key rewrites only that pair, keeping the row's others.
mux_prof_set waybar theme green
eq set-update "$(mux_prof_get waybar theme)" "green"
eq set-keeps-root "$(mux_prof_get waybar root)" "$T/waybar"
eq set-keeps-layout "$(mux_prof_get waybar layout)" "logs"
# Adding a new key to an existing row appends it.
mux_prof_set api layout logs
eq set-add "$(mux_prof_get api layout)" "logs"
eq set-add-keeps "$(mux_prof_get api theme)" "cyan"
# A name with no row gets one.
mux_prof_set fresh theme red
eq set-new "$(mux_prof_get fresh theme)" "red"
eq set-new-listed "$(mux_prof_names | tr '\n' ' ')" "api kg waybar fresh "
# Comments and blank lines survive every write.
grep -q '^# a comment' "$MUX_DIR/profiles" || fail "set: a comment was lost"
grep -qx '' "$MUX_DIR/profiles" || fail "set: the blank line was lost"

# --- dropping ---------------------------------------------------------------
mux_prof_drop kg
eq drop "$(mux_prof_names | tr '\n' ' ')" "api waybar fresh "
eq drop-gone "$(mux_prof_get kg root)" ""
grep -q '^# a comment' "$MUX_DIR/profiles" || fail "drop: a comment was lost"
# Dropping something absent is a no-op, not an error.
mux_prof_drop nosuch || fail "drop: an absent name should be a no-op"

# --- no table at all --------------------------------------------------------
rm -f "$MUX_DIR/profiles"
eq empty-names "$(mux_prof_names)" ""
eq empty-get "$(mux_prof_get api theme)" ""
eq empty-by-root "$(mux_prof_by_root "$T/waybar")" ""
mux_prof_has api && fail "has: nothing should be present with no table"

# ... and the first write creates it, with its header.
mux_prof_set solo theme cyan
eq create "$(mux_prof_get solo theme)" "cyan"
grep -q '^# mux profiles' "$MUX_DIR/profiles" \
	|| fail "create: no header written"

pass
