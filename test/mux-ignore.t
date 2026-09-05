#!/bin/sh
# test/mux-ignore.t - `ignore` prunes DISCOVERY, so two repos sharing a basename
# can stop being ambiguous without renaming either of them.
#
# The shape that forced it: a work tree holding both ~/src/manifest/ManifestOS
# and ~/src/manifest/athena-repos/ManifestOS. An alias does not resolve that --
# both roots keep the basename, so `mux go ManifestOS` stays ambiguous forever.
# Dropping one from the map does.
#
# Multiplicity deliberately copies `scan`: repeatable within a file, and a file
# that sets it REPLACES the inherited list rather than extending it. The format
# already had one answer for "a key that is a list" and a second convention
# would be a second thing to remember.
set -eu
_name=mux-ignore
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/conf/contexts" "$T/cache"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
for d in src/dup src/nested/dup src/solo src/vendor/thing; do
	mkdir -p "$T/$d/.git"
done
printf '#!/bin/sh\necho work\n' >"$T/conf/cc"; chmod +x "$T/conf/cc"
printf 'context-command cc\n' >"$T/conf/config"

# part IGNORE-LINES : rewrite the partition file with the given ignore body.
part() {
	{ printf 'scan %s/src 3\n' "$T"; [ -n "${1:-}" ] && printf '%s\n' "$1"; } \
		>"$T/conf/partitions/work.partition"
	rm -f "$T/cache/projects.work"
}
run() {
	_d=$1; shift
	( cd "$_d" && env -u MUX_SHARE -u TMUX -u TMUX_PANE \
		MUX_DIR="$T/conf" MUX_CACHE="$T/cache" PATH="$T/bin:$PATH" \
		"$HERE/bin/mux" "$@" 2>&1 )
}
# the names the map ended up holding, space separated and sorted
names() { cut -f1 "$T/cache/projects.work" | LC_ALL=C sort | tr '\n' ' '; }
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in: $1" ;; esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in: $1" ;; esac; }

# --- baseline: no ignore, the collision is present -------------------------
part ""
run "$T" scan >/dev/null 2>&1
[ "$(names)" = "dup dup solo thing " ] || fail "baseline map: [$(names)]"

# --- rule 1: a pattern WITH a slash globs the whole path -------------------
part 'ignore */nested/*'
_o=$(run "$T" scan)
[ "$(names)" = "dup solo thing " ] || fail "path glob: [$(names)]"
has "$_o" "ignored 1 path(s)" "path glob: count not reported"
no_has "$_o" "ambiguous" "path glob: collision survived"

# --- rule 2: a pattern with NO slash matches one path COMPONENT ------------
# Without this rule `ignore vendor` would silently match nothing, which is the
# footgun a whole-path-only design ships with.
part 'ignore vendor'
run "$T" scan >/dev/null 2>&1
[ "$(names)" = "dup dup solo " ] || fail "component match: [$(names)]"

# --- repeatable WITHIN a file, exactly like scan ---------------------------
part 'ignore */nested/*
ignore vendor'
_o=$(run "$T" scan)
[ "$(names)" = "dup solo " ] || fail "two ignores: [$(names)]"
has "$_o" "ignored 2 path(s)" "two ignores: count"

# --- a CONTEXT file REPLACES the partition's list, never extends it --------
# So a context can drop what its partition ignores; that is the whole reason
# scan works this way, and ignore must not differ.
part 'ignore */nested/*
ignore vendor'
printf 'ignore vendor\n' >"$T/conf/contexts/work.context"
run "$T" scan >/dev/null 2>&1
[ "$(names)" = "dup dup solo " ] || fail "context replace: [$(names)]"
# ... and a context that says nothing about ignore inherits the partition's.
printf '# nothing about ignore\n' >"$T/conf/contexts/work.context"
rm -f "$T/cache/projects.work"
run "$T" scan >/dev/null 2>&1
[ "$(names)" = "dup solo " ] || fail "context silent: [$(names)]"
rm -f "$T/conf/contexts/work.context"

# --- a pattern matching NOTHING is almost always a typo, and says so -------
# A filter that silently does nothing looks exactly like one that works.
part 'ignore */nsted/*'
_o=$(run "$T" scan)
has "$_o" "matched NOTHING" "typo: no warning"
[ "$(names)" = "dup dup solo thing " ] || fail "typo: map changed: [$(names)]"

# --- DISCOVERY only: an explicit path still reaches an ignored repo --------
# A path you typed is evidence. ignore governs what mux VOLUNTEERS, never what
# you can ask for by name -- otherwise mux is arguing with you.
part 'ignore */nested/*'
run "$T" scan >/dev/null 2>&1
_o=$(run "$T" why "$T/src/nested/dup")
has "$_o" "$T/src/nested/dup" "explicit path: ignored anyway"
has "$_o" "the path you gave" "explicit path: wrong provenance"

# --- and with the collision gone, the name simply resolves -----------------
_o=$(run "$T" why dup)
has "$_o" "$T/src/dup" "after ignore: name did not resolve"
no_has "$_o" "(ambiguous)" "after ignore: still ambiguous"

pass
