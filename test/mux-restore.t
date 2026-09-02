#!/bin/sh
# test/mux-restore.t - `mux restore` end to end: reboot the machine, get your
# sessions back. Drives the real front end with a stubbed tmux, so the
# recording, the resolution and the rebuild are all exercised.
#
# The stub models a server whose live set lives in a file, so "reboot" is just
# truncating it while the cache survives -- which is exactly the situation the
# feature exists for, and the one a snapshot-based design would break.
set -eu
_name=mux-restore
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
	exit 0; }

mkdir -p "$T/bin" "$T/conf" "$T/tree/alpha" "$T/tree/bravo" "$T/elsewhere"
for _d in alpha bravo; do git init -q "$T/tree/$_d"; done

cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
# LIVE holds "name<TAB>root" per running session.
case "$*" in
*has-session*)
	_n=${*##*=}
	cut -f1 "$LIVE" 2>/dev/null | grep -qxF "$_n" && exit 0
	exit 1 ;;
*list-sessions*)
	[ -s "$LIVE" ] || exit 1
	case "$*" in
	*session_path*) sed 's/\t/ /' "$LIVE" ;;
	*) cut -f1 "$LIVE" ;;
	esac ;;
*new-session*)
	# -s NAME ... -c ROOT
	_n=; _c=
	while [ $# -gt 0 ]; do
		case $1 in -s) _n=$2; shift ;; -c) _c=$2; shift ;; esac; shift
	done
	printf '%s\t%s\n' "$_n" "$_c" >>"$LIVE" ;;
*kill-session*)
	_n=${*##*=}
	grep -v "^$_n	" "$LIVE" >"$LIVE.t" 2>/dev/null; mv -f "$LIVE.t" "$LIVE" ;;
*kill-server*) : >"$LIVE" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
LIVE=$T/live; : >"$LIVE"; export LIVE
PATH=$T/bin:$PATH; export PATH

mux() {
	_d=$1; shift
	( cd "$_d" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" GIT_CEILING_DIRECTORIES="$T" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
live() { cut -f1 "$LIVE" | sort | tr '\n' ' '; }

# --- opening sessions records them, with their roots ------------------------
mux "$T/tree/alpha" go >/dev/null || fail "go alpha failed"
mux "$T/tree/bravo" go >/dev/null || fail "go bravo failed"
_set=$(mux "$T/elsewhere" restore --list | tr '\n' ' ')
[ "$_set" = "alpha bravo " ] || fail "recorded set is [$_set]"

# --- reboot: the server is gone, the cache is not ---------------------------
: >"$LIVE"
[ "$(live)" = " " ] || [ -z "$(live)" ] || fail "the fake reboot left sessions"

# Restore from a directory that is NEITHER session's root, to prove it uses the
# recorded roots and not the cwd.
_o=$(mux "$T/elsewhere" restore) || fail "restore failed: $_o"
case $_o in *"restored 2"*) ;; *) fail "expected 2 restored: [$_o]" ;; esac
[ "$(live)" = "alpha bravo " ] || fail "after restore, live is [$(live)]"
# ... and each landed back at its own root, not at $T/elsewhere.
grep -q "^alpha	$T/tree/alpha$" "$LIVE" \
	|| fail "alpha restored to the wrong root"
grep -q "^bravo	$T/tree/bravo$" "$LIVE" \
	|| fail "bravo restored to the wrong root"

# --- idempotent -------------------------------------------------------------
_o=$(mux "$T/elsewhere" restore) || fail "second restore failed"
case $_o in *"2 already up"*) ;; *) fail "expected both already up: [$_o]" ;;
esac

# --- killing forgets, so a restore does not resurrect it --------------------
mux "$T/elsewhere" kill alpha >/dev/null || fail "kill failed"
_set=$(mux "$T/elsewhere" restore --list | tr '\n' ' ')
[ "$_set" = "bravo " ] || fail "kill did not prune the set: [$_set]"
: >"$LIVE"
mux "$T/elsewhere" restore >/dev/null || fail "restore after kill failed"
[ "$(live)" = "bravo " ] || fail "a killed session was resurrected: [$(live)]"

# --- one broken entry must not cost the others ------------------------------
mux "$T/tree/alpha" go >/dev/null || fail "re-open alpha failed"
rm -rf "$T/tree/alpha"
: >"$LIVE"
_o=$(mux "$T/elsewhere" restore) || fail "restore with a dead root failed"
case $_o in *"could NOT build"*) ;; *) fail "no report of the dead root" ;; esac
[ "$(live)" = "bravo " ] || fail "the good session was lost: [$(live)]"

# --- nothing recorded is a loud, non-zero answer ----------------------------
rm -f "$T"/cache/sessions.*
_o=$(mux "$T/elsewhere" restore) \
	&& fail "restore with no set should exit non-zero"
case $_o in *"no sessions recorded"*) ;; *) fail "unhelpful message: [$_o]" ;;
esac

pass
