#!/bin/sh
# test/mux-discover.t - the resolution cascade for `mux go`:
#   1 a live session, 2 a table row, 3 a breakout profile, 4 the scan map,
#   5 nothing -> REFUSE.
# The premise of step 5 is that with no evidence at all, "a new session" and "a
# typo" are indistinguishable from the input, so mux refuses and hands over both
# fixes. Bare `mux go` never reaches step 5: the directory is the evidence.
#
# tmux is stubbed, so no server starts. Scratch repos, scratch MUX_DIR/CACHE.
set -eu
_name=mux-discover
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
	exit 0; }

mkdir -p "$T/bin" "$T/conf" "$T/tree/alpha" "$T/tree/nested/alpha" \
	"$T/tree/solo" "$T/elsewhere"
for _d in alpha nested/alpha solo; do git init -q "$T/tree/$_d"; done
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; export TMUXLOG
PATH=$T/bin:$PATH; export PATH
# Scan roots live in the partition now, not $MUX_DIR/scan. Overriding the
# SHIPPED global.partition matters: without this the test would scan the
# developer's real ~/src.
mkdir -p "$T/conf/partitions"
printf 'scan %s 3\n' "$T/tree" >"$T/conf/partitions/global.partition"

# mux DIR ARGS... -> run from DIR, echoing combined output.
mux() {
	_d=$1; shift
	( cd "$_d" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" GIT_CEILING_DIRECTORIES="$T" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
# rooted -> the -c directory of the new-session call in the last run.
rooted() {
	awk '/new-session /{for(i=1;i<=NF;i++) if($i=="-c") print $(i+1)}' \
		"$TMUXLOG" | head -1
}
fails() {  # LABEL WANT DIR ARGS...
	_l=$1 _w=$2; shift 2
	_o=$(mux "$@") && fail "$_l: expected a non-zero exit, got [$_o]"
	case $_o in *"$_w"*) ;; *) fail "$_l: want [$_w], got [$_o]" ;; esac
}

mux "$T/tree" scan >/dev/null || fail "mux scan failed"

# --- step 4: a name never configured, from a directory that is not it -------
: >"$TMUXLOG"
mux "$T/elsewhere" go solo >/dev/null || fail "go solo (via the map) failed"
[ "$(rooted)" = "$T/tree/solo" ] \
	|| fail "map lookup: rooted at [$(rooted)], want $T/tree/solo"

# --- step 5: an unknown name is refused, with both fixes offered ------------
fails unknown       "nothing known as 'sola'"   "$T/elsewhere" go sola
fails unknown-fix   "mux new sola"              "$T/elsewhere" go sola
# ... and the near-miss is actually suggested, which is what makes the
# strictness bearable. A prefix test would miss this one.
fails unknown-near  "did you mean"              "$T/elsewhere" go sola
fails unknown-near2 "solo"                      "$T/elsewhere" go sola

# --- bare `mux go` NEVER reaches step 5 -------------------------------------
# No name was typed, so nothing could have been mistyped; the cwd is evidence.
: >"$TMUXLOG"
mux "$T/elsewhere" go >/dev/null || fail "bare go in an unknown dir was refused"
[ "$(rooted)" = "$T/elsewhere" ] \
	|| fail "bare go: rooted at [$(rooted)], want $T/elsewhere"

# --- an ambiguous name lists the candidates rather than guessing ------------
fails ambiguous "is ambiguous" "$T/elsewhere" go alpha
fails ambiguous-lists "nested/alpha" "$T/elsewhere" go alpha

# --- mux new binds a name, and only when a row is needed --------------------
: >"$TMUXLOG"
mux "$T/tree/nested/alpha" new alpha2 >/dev/null || fail "mux new failed"
grep -q '^alpha2 ' "$T/conf/profiles" \
	|| fail "new: no row written for a non-derivable name"
grep -q "root=$T/tree/nested/alpha" "$T/conf/profiles" \
	|| fail "new: the row does not carry the root"
# A name this directory already derives needs NO row: config never restates
# what mux can derive.
: >"$TMUXLOG"
mux "$T/tree/solo" new solo >/dev/null || fail "mux new solo (derivable) failed"
grep -q '^solo ' "$T/conf/profiles" 2>/dev/null \
	&& fail "new: wrote a row for a name the directory already derives"
# ... but binding a name that already means a DIFFERENT project is refused,
# since that would silently change what `mux go <name>` means everywhere else.
fails new-rebind "already means" "$T/tree/nested/alpha" new solo

# --- step 2: the row now answers, and owns its directory --------------------
: >"$TMUXLOG"
mux "$T/elsewhere" go alpha2 >/dev/null || fail "go alpha2 (via the row) failed"
[ "$(rooted)" = "$T/tree/nested/alpha" ] \
	|| fail "row lookup: rooted at [$(rooted)]"
# Bare `mux go` in that directory must resolve to the ALIAS, not to the name
# the directory would otherwise derive -- else you get two sessions on one dir.
: >"$TMUXLOG"
mux "$T/tree/nested/alpha" go >/dev/null \
	|| fail "bare go in the alias dir failed"
grep -q 'new-session -d -s alpha2 ' "$TMUXLOG" \
	|| fail "bare go in an aliased directory did not resolve to the alias"

# --- new refuses a name that is already known -------------------------------
fails new-dup "already has a profile" "$T/tree/solo" new alpha2

pass
