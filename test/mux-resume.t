#!/bin/sh
# test/mux-resume.t - `mux resume` end to end: reboot the machine, get your
# sessions back. Drives the real front end with a stubbed tmux, so the
# recording, the resolution and the rebuild are all exercised.
#
# The stub models a server whose live set lives in a file, so "reboot" is just
# truncating it while the cache survives -- which is exactly the situation the
# feature exists for, and the one a snapshot-based design would break.
set -eu
_name=mux-resume
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
_set=$(mux "$T/elsewhere" resume --list | tr '\n' ' ')
[ "$_set" = "alpha bravo " ] || fail "recorded set is [$_set]"

# --- reboot: the server is gone, the cache is not ---------------------------
: >"$LIVE"
[ "$(live)" = " " ] || [ -z "$(live)" ] || fail "the fake reboot left sessions"

# Restore from a directory that is NEITHER session's root, to prove it uses the
# recorded roots and not the cwd.
_o=$(mux "$T/elsewhere" resume) || fail "resume failed: $_o"
case $_o in *"resumed 2"*) ;; *) fail "expected 2 resumed: [$_o]" ;; esac
[ "$(live)" = "alpha bravo " ] || fail "after resume, live is [$(live)]"
# ... and each landed back at its own root, not at $T/elsewhere.
grep -q "^alpha	$T/tree/alpha$" "$LIVE" \
	|| fail "alpha resumed to the wrong root"
grep -q "^bravo	$T/tree/bravo$" "$LIVE" \
	|| fail "bravo resumed to the wrong root"

# --- idempotent -------------------------------------------------------------
_o=$(mux "$T/elsewhere" resume) || fail "second resume failed"
case $_o in *"2 already up"*) ;; *) fail "expected both already up: [$_o]" ;;
esac

# --- killing forgets, so a resume does not resurrect it --------------------
mux "$T/elsewhere" kill alpha >/dev/null || fail "kill failed"
_set=$(mux "$T/elsewhere" resume --list | tr '\n' ' ')
[ "$_set" = "bravo " ] || fail "kill did not prune the set: [$_set]"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null || fail "resume after kill failed"
[ "$(live)" = "bravo " ] || fail "a killed session was resurrected: [$(live)]"

# --- resume addresses each session by its ROOT, the public form ------------
# Not by a private path through the resolver: `mux go <dir>` is a command
# anyone can type, so resume is a loop over it. Proven by a session whose root
# is a repo SUBDIRECTORY -- addressing it by name alone could not distinguish
# it from its enclosing repo.
mkdir -p "$T/tree/bravo/inner"
printf 'inner       root=%s/tree/bravo/inner\n' "$T" >"$T/conf/profiles"
mux "$T/tree/bravo/inner" go inner >/dev/null || fail "opening inner failed"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null || fail "resume with a subdir failed"
grep -q "^inner	$T/tree/bravo/inner$" "$LIVE" \
	|| fail "the subdirectory session did not come back at its own root"
rm -f "$T/conf/profiles"

# --- one broken entry must not cost the others ------------------------------
mux "$T/tree/alpha" go >/dev/null || fail "re-open alpha failed"
rm -rf "$T/tree/alpha"
: >"$LIVE"
_o=$(mux "$T/elsewhere" resume) || fail "resume with a dead root failed"
case $_o in *"could NOT build"*) ;; *) fail "no report of the dead root" ;; esac
[ "$(live)" = "bravo " ] || fail "the good session was lost: [$(live)]"

# --- ... and a dead entry can be FORGOTTEN ----------------------------------
# The set is pruned ONLY by `kill`, which used to require the session to be
# LIVE. But an entry whose root has gone is already dead: it could not be
# killed, so it could never be forgotten, and `resume` reported it as
# unbuildable on every run with no way out short of editing $MUX_CACHE by hand.
# Killing something already dead is still exactly what you mean.
mux_recorded() { mux "$T/elsewhere" resume --list | grep -qxF "$1"; }
mux_recorded alpha || fail "precondition: alpha should still be recorded"
_o=$(mux "$T/elsewhere" kill alpha) || fail "kill of a dead record failed: $_o"
case $_o in *forgotten*) ;; *) fail "kill of a dead record was silent: [$_o]" ;;
esac
mux_recorded alpha && fail "the dead entry survived kill"
# ... so resume stops reporting it.
: >"$LIVE"
_o=$(mux "$T/elsewhere" resume) || fail "resume after forgetting failed"
case $_o in
*"could NOT build"*) fail "resume still reports the forgotten entry: [$_o]" ;;
esac

# Neither live nor recorded is still an ERROR. Forgetting is for something mux
# actually remembers; a blanket success would make a typo look like a kill.
_o=$(mux "$T/elsewhere" kill nosuchsession) \
	&& fail "kill of an unknown name should exit non-zero"
case $_o in *"no such session"*) ;; *) fail "unhelpful refusal: [$_o]" ;; esac

# --- a recorded name containing a SPACE is rebuilt whole --------------------
# `for n in $set` word-split the recorded names, so a session called
# `my project` was rebuilt as two phantoms -- `my` and `project` -- and the
# real one never came back. The set is newline separated for exactly this
# reason: a session name may contain a space, never a newline.
rm -f "$T"/state/sessions.*
: >"$LIVE"
mkdir -p "$T/tree/my project"
git init -q "$T/tree/my project" 2>/dev/null || true
# A BARE `go` from inside the directory: the directory is evidence, so the
# name is derived from its basename. A typed name nothing knows is refused by
# design, which is a different behaviour and not the one under test.
mux "$T/tree/my project" go >/dev/null 2>&1 \
	|| fail "opening a spaced-name session failed"
_set=$(mux "$T/elsewhere" resume --list)
printf '%s\n' "$_set" | grep -qxF 'my project' \
	|| fail "the spaced name was not recorded whole: [$_set]"
printf '%s\n' "$_set" | grep -qxF 'my' \
	&& fail "the set holds a phantom 'my': [$_set]"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null 2>&1 || true
grep -q "^my project	" "$LIVE" \
        || fail "the spaced session was not rebuilt: [$(cat "$LIVE")]"
grep -q "^my	" "$LIVE" && fail "a phantom session 'my' was built"

# --- nothing recorded is a loud, non-zero answer ----------------------------
rm -f "$T"/state/sessions.*
_o=$(mux "$T/elsewhere" resume) \
	&& fail "resume with no set should exit non-zero"
case $_o in *"no sessions recorded"*) ;; *) fail "unhelpful message: [$_o]" ;;
esac

pass
