#!/bin/sh
# test/mux-session-names.t - a session name is not a word.
#
# tmux accepts a session named `my project`, and reports it intact from
# `list-sessions -F '#{session_name}'`. Two separate bugs followed from
# treating such a name as whitespace-delimited:
#
#   the ring   `for s in $(tmux list-sessions -F ...)` word-splits, so one
#              session became two phantom entries and the real one was never
#              reachable. The target uses tmux's exact-match `=`, so the switch
#              failed SILENTLY -- and mux-cycle is silent by contract (it runs
#              from a key binding), so prefix ( and ) simply went dead.
#
#   the hidden set  was joined with SPACES and searched with
#              `case " $set " in *" $name "*)`, making every WORD of a hidden
#              name a member. `mux hide "my project"` also hid unrelated
#              sessions called `my` and `project`.
#
# They are independent -- fixing the loops does not fix the set -- but they are
# one class, so they are pinned together.
#
# THE STUB WAS CHECKED AGAINST REAL TMUX before this was written, which matters
# because a stub that models the tool wrongly makes a test that can never fail.
# Verified by hand on an isolated `tmux -L` socket: a session named `my project`
# is accepted; `list-sessions -F '#{session_name}'` prints it on ONE line;
# `has-session -t '=my project'` finds it while `-t '=my'` does not; and a name
# containing a literal newline comes back ESCAPED as `a\nb`, which is what makes
# newline a safe delimiter for a set of names and a space an unsafe one. The
# whole fix was then driven end to end against that real server.
set -eu
_name=mux-session-names
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/run/mux-exclude" "$T/run/agent-state/global"
SESSIONS=$T/sessions
OUT=$T/out
export SESSIONS OUT
printf 'alpha\nmy project\nzulu\n' >"$SESSIONS"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*) cat "$SESSIONS" ;;
*list-panes*)    printf '%%1\n%%2\n%%3\n' ;;
*show-options*)  printf '\n' ;;
*list-clients*)  printf '/dev/pts/0 80x24 alpha 1\n' ;;
*client_width*)  printf '80x24 80x23 latest on alpha\n' ;;
*switch-client*) printf '%s\n' "$*" >>"$OUT" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

CK=$(printf '%s' client0 | tr -c 'A-Za-z0-9' '_')
hide() { printf '%s\n' "$@" >"$T/run/mux-exclude/$CK"; }
unhide() { rm -f "$T/run/mux-exclude/$CK"; }
cyc() {
	: >"$OUT"
	env XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH" \
		"$HERE/libexec/mux-cycle" "$@" >/dev/null 2>&1 || true
	# the target, with the exact-match '=' stripped
	sed -n 's/.*-t =//p' "$OUT" | head -1
}

# --- the ring keeps a spaced name WHOLE, and in the right place -----------
unhide
_r=$(cyc next client0 alpha)
[ "$_r" = "my project" ] \
	|| fail "next from alpha reached [$_r], want 'my project'"
_r=$(cyc next client0 'my project')
[ "$_r" = zulu ] || fail "next from 'my project' reached [$_r], want zulu"
_r=$(cyc prev client0 zulu)
[ "$_r" = "my project" ] \
	|| fail "prev from zulu reached [$_r], want 'my project'"
# ... and it wraps, which word-splitting also broke by inflating the ring.
_r=$(cyc next client0 zulu)
[ "$_r" = alpha ] || fail "next from zulu should wrap to alpha, got [$_r]"

# A phantom is the specific symptom: a bare `my` or `project` must never be a
# target, because no such session exists and the switch would fail silently.
for _bad in my project; do
	_r=$(cyc next client0 "$_bad")
	[ "$_r" != "$_bad" ] || fail "'$_bad' was treated as a real session"
done

# --- hiding is EXACT, not per word ---------------------------------------
hide 'my project'
_r=$(cyc next client0 alpha)
[ "$_r" = zulu ] || fail "hiding 'my project' did not skip it: got [$_r]"
# The words of the hidden name are NOT hidden. Proven through the ring: with
# the set holding only `my project`, a session actually named `my` must still
# be reachable.
printf 'alpha\nmy\nzulu\n' >"$SESSIONS"
_r=$(cyc next client0 alpha)
[ "$_r" = my ] || fail "a session named 'my' was hidden by 'my project': [$_r]"
printf 'alpha\nproject\nzulu\n' >"$SESSIONS"
_r=$(cyc next client0 alpha)
[ "$_r" = project ] \
	|| fail "a session named 'project' was hidden by 'my project': [$_r]"
printf 'alpha\nmy project\nzulu\n' >"$SESSIONS"
unhide

# --- next-blocked walks the same ring, and it is the headline feature -----
# "take me to whoever has waited longest" is the reason prefix+b exists, and it
# shared the word-splitting loop.
# Record: state window pane epoch notif SESSION -- session LAST, which is the
# whole point here: `my project` must come back whole.
st() { agent_rec "$T/run/agent-state/global/${1#%}" "$2" "$1" 1 "$3"; }
st %2 blocked 'my project'
st %3 blocked zulu
nb() {
	: >"$OUT"
	env -u TMUX XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH" \
		"$HERE/libexec/mux-next-blocked" client0 alpha >/dev/null 2>&1 || true
	sed -n 's/.*-t =//p' "$OUT" | head -1
}
_r=$(nb)
[ "$_r" = "my project" ] \
	|| fail "next-blocked reached [$_r]; the spaced name blocked longest"
# ... and it honours the hidden set exactly too.
hide 'my project'
_r=$(nb)
[ "$_r" = zulu ] || fail "next-blocked ignored the hidden set: got [$_r]"
unhide

# --- the RECORD itself must hold a spaced name ---------------------------
# Writing the fixtures by hand above proves the readers; it cannot prove the
# WRITER, which is where the third instance of this class lived. The emitter
# asked tmux for `#{session_name} #{window_index}` and wrote the pair into the
# middle of a space-separated record, so a session called `my project` produced
# a line nothing could parse: it got no agent chip at all, and a session
# actually named `my` picked up its state. So drive the real emitter.
mkdir -p "$T/emitbin"
cat >"$T/emitbin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
# The order under test: window index first, session name last.
*window_index*session_name*) printf '0 my project
' ;;
*session_name*window_index*) printf 'my project 0
' ;;
*mux-notify-always*)         printf '
' ;;
*pane_active*)               printf '1
' ;;   # visible: raise no banner
esac
exit 0
EOF
chmod +x "$T/emitbin/tmux"
rm -f "$T/run/agent-state/global"/*
env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%7 \
	PATH="$T/emitbin:$PATH" "$HERE/libexec/agent-state-emit" working \
	>/dev/null 2>&1 || fail "emit failed"
_rec=$(cat "$T/run/agent-state/global/7")
_found=$(env XDG_RUNTIME_DIR="$T/run" sh -c '
	. "$1/libexec/mux-agent-state.sh"
	mux_agent_state "$(mux_agent_dir global)" "my project"' _ "$HERE")
case ${_found%% *} in
working) ;;
*) fail "the emitted record lost the spaced name: [$_rec] -> [$_found]" ;;
esac
# ... and a session named after its FIRST WORD must not inherit that state.
_stolen=$(env XDG_RUNTIME_DIR="$T/run" sh -c '
	. "$1/libexec/mux-agent-state.sh"
	mux_agent_state "$(mux_agent_dir global)" "my"' _ "$HERE")
[ -z "${_stolen%% *}" ] \
	|| fail "a session named 'my' inherited 'my project' state: [$_stolen]"
rm -f "$T/run/agent-state/global"/*
st %2 blocked 'my project'
st %3 blocked zulu

# --- the strip shows the whole name, and hides exactly ---------------------
# agent-state-render always read line by line, so it never had the ring bug --
# but it shared the hidden-set test.
render() {
	env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" MUX_STRIP_WIDTH=400 \
		PATH="$T/bin:$PATH" "$HERE/libexec/agent-state-render" \
		alpha client0 2>/dev/null | sed 's/#\[[^]]*\]//g'
}
case "$(render)" in
*"my project"*) ;;
*) fail "the strip lost the spaced name: [$(render)]" ;;
esac
hide 'my project'
case "$(render)" in
*"my project"*) fail "a hidden session is still on the strip" ;;
esac
# alpha and zulu survive -- hiding one name must not take out its neighbours.
case "$(render)" in
*alpha*zulu*) ;;
*) fail "hiding took out other sessions: [$(render)]" ;;
esac

pass
