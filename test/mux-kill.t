#!/bin/sh
# test/mux-kill.t - tearing sessions down, the one path that destroys work.
#
# `mux kill --all` runs `tmux kill-server`: every session in the context, every
# pane, every running agent, gone at once and unrecoverable. It had NO test. An
# external audit gave it credit for being carefully written ("requires a typed
# yes", "targets -t =NAME so a prefix collision cannot kill the wrong session")
# and said the real gap was that nothing HOLDS those guards in place: they were
# correct by authorship, not by construction. This is that construction.
#
# The assertions are about refusals, because that is where the value is. A kill
# that works is easy; a kill that declines when it should is the whole guard.
#
# Also pinned: the recorded session set is cleared. Without that, `mux resume`
# would faithfully rebuild everything you just chose to destroy, which is the
# one way a confirmed kill could still surprise you.
set -eu
_name=mux-kill
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/proj"

# The stub records every destructive call, so a test can assert one did NOT
# happen -- the point of most cases here.
LIVE=$T/live
KILLED=$T/killed
export LIVE KILLED
: >"$KILLED"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*kill-server*)
	printf 'kill-server\n' >>"$KILLED"; : >"$LIVE" ;;
*kill-session*)
	_n=${*##*=}
	printf 'kill-session %s\n' "$_n" >>"$KILLED"
	grep -vxF "$_n" "$LIVE" >"$LIVE.t" 2>/dev/null || :
	mv -f "$LIVE.t" "$LIVE" ;;
*has-session*)
	_n=${*##*=}
	grep -qxF "$_n" "$LIVE" 2>/dev/null && exit 0
	exit 1 ;;
*list-sessions*)
	[ -s "$LIVE" ] || exit 1
	cat "$LIVE" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/global.partition"

# mux ANSWER VERB... : run with ANSWER on stdin (the confirmation prompt).
mux() {
	_ans=$1; shift
	printf '%s\n' "$_ans" | ( cd "$T/proj" && env -u MUX_SHARE -u TMUX \
		PATH="$T/bin:$PATH" MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
live()   { sort "$LIVE" 2>/dev/null | tr '\n' ' '; }
killed() { cat "$KILLED"; }
reset()  {
	printf 'alpha\nbravo\ncharlie\n' >"$LIVE"
	: >"$KILLED"
	mkdir -p "$T/cache"
	printf 'alpha\t%s\nbravo\t%s\ncharlie\t%s\n' "$T/proj" "$T/proj" \
		"$T/proj" >"$T/state/sessions.global"
}
recorded() { cut -f1 "$T/state/sessions.global" 2>/dev/null | tr '\n' ' '; }

# --- an unconfirmed kill --all MUST NOT kill anything ----------------------
# The load-bearing case. Every one of these answers means "no", and the only
# acceptable outcome is that all three sessions are still there afterwards.
for _no in "" "n" "no" "NO" "nope" "yes please" "Y E S" "1" "q"; do
	reset
	_o=$(mux "$_no" kill --all)
	case $_o in
	*aborted*|*"no sessions"*) ;;
	*) fail "answer [$_no]: expected an abort, got: $_o" ;;
	esac
	[ -z "$(killed)" ] \
		|| fail "answer [$_no] DESTROYED sessions: $(killed)"
	[ "$(live)" = "alpha bravo charlie " ] \
		|| fail "answer [$_no] changed the live set: [$(live)]"
	[ "$(recorded)" = "alpha bravo charlie " ] \
		|| fail "answer [$_no] cleared the recorded set: [$(recorded)]"
done

# --- it shows you WHAT you are about to lose, before asking ---------------
# A confirmation you cannot audit is a reflex, not a decision.
reset
_o=$(mux no kill --all)
for _s in alpha bravo charlie; do
	printf '%s\n' "$_o" | grep -q "$_s" \
		|| fail "the prompt did not name session $_s: $_o"
done
case $_o in
*"cannot be undone"*) ;;
*) fail "the prompt did not say it is irreversible: $_o" ;;
esac
case $_o in
*"3 session"*) ;;
*) fail "the prompt did not count the sessions: $_o" ;;
esac

# --- a confirmed kill --all tears down AND forgets ------------------------
# Forgetting matters as much as killing: the recorded set is what `mux resume`
# rebuilds from, so a set left intact would resurrect everything you just
# deliberately destroyed.
reset
_o=$(mux yes kill --all)
printf '%s\n' "$(killed)" | grep -qx 'kill-server' \
	|| fail "a confirmed kill --all did not kill the server: [$(killed)]"
[ -z "$(live)" ] || fail "sessions survived a confirmed kill: [$(live)]"
[ -z "$(recorded)" ] \
	|| fail "the recorded set survived, so resume would rebuild: [$(recorded)]"

# --- the accepted answers, as the code actually defines them --------------
# Documenting rather than endorsing: the prompt says "Type yes", and a bare `y`
# is also accepted. That is a LOWER bar than the prompt advertises for an
# irreversible action. Pinned so the set cannot widen silently; narrowing it to
# match the prompt would be a deliberate change, and this test would say so.
for _yes in yes YES y Y; do
	reset
	mux "$_yes" kill --all >/dev/null
	printf '%s\n' "$(killed)" | grep -qx 'kill-server' \
		|| fail "answer [$_yes] did not confirm: [$(killed)]"
done

# --- no sessions at all is not an error, and kills nothing ---------------
: >"$LIVE"; : >"$KILLED"
_o=$(mux yes kill --all)
case $_o in
*"no sessions"*) ;;
*) fail "an empty context should say so: $_o" ;;
esac
[ -z "$(killed)" ] || fail "kill --all ran kill-server on an empty context"

# --- single kill is EXACT, never a prefix match --------------------------
# `kill api` must not take out `api-old`. The front end targets `-t =NAME`, and
# tmux's `=` is the exact-match form; this holds that choice in place.
reset
printf 'api\napi-old\n' >"$LIVE"
: >"$KILLED"
mux "" kill api >/dev/null
printf '%s\n' "$(killed)" | grep -qx 'kill-session api' \
	|| fail "kill api did not kill api: [$(killed)]"
printf '%s\n' "$(killed)" | grep -q 'api-old' \
	&& fail "kill api also killed api-old"
[ "$(live)" = "api-old " ] || fail "wrong survivor set: [$(live)]"

# --- killing an unknown name is a loud refusal, not a silent success ----
reset
_rc=0; _o=$(mux "" kill nosuchthing) || _rc=$?
[ "$_rc" -ne 0 ] || fail "killing an unknown name exited 0"
case $_o in
*"no such session"*) ;;
*) fail "unhelpful refusal for an unknown name: $_o" ;;
esac
[ -z "$(killed)" ] || fail "an unknown name still killed something"

pass
