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
# --- raising a NOTIFICATION must not clobber the session -------------------
# The emit path computes $_sess once, at the top, from `#{window_index}
# #{session_name}`. The notification block used to RE-derive it as ${loc%% *},
# which was correct only while the probe asked for session FIRST. Flipping that
# order fixed the top copy and left this one reading the WINDOW INDEX, so any
# emit that raised a banner wrote a record naming a session `0`.
#
# The damage was invisible where it happened and loud where it did not: the
# real session showed NO agent state at all (it looked idle while the agent
# worked), and the banner read "Claude finished: 0". Observed live on a
# `vigilance` session; pane %4 held `idle 0 %4 <epoch> 460 0`.
#
# The existing emitter case above cannot catch it: its stub reports the pane as
# VISIBLE, and a visible pane raises no banner, so it never enters this block.
# This one forces the banner -- previous state `working`, new state `idle`,
# pane not visible -- which is the only path that was broken.
mkdir -p "$T/notifbin"
cat >"$T/notifbin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*window_index*session_name*) printf '0 my project
' ;;
*mux-notify-always*)         printf '
' ;;
*pane_active*)               printf '0
' ;;   # NOT visible: raise the banner
esac
exit 0
EOF
chmod +x "$T/notifbin/tmux"
# The notify seam, stubbed: log the summary, return an id.
cat >"$T/notifbin/send" <<'EOF'
#!/bin/sh
printf '%s
' "$2" >>"$NLOG"
printf '777
'
EOF
chmod +x "$T/notifbin/send"
NLOG=$T/nlog; : >"$NLOG"; export NLOG

rm -f "$T/run/agent-state/global"/*
# Previous state must be `working` for the transition to fire.
agent_rec "$T/run/agent-state/global/8" working %8 100 'my project'
env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%8 \
	MUX_NOTIFY_SEND="$T/notifbin/send" PATH="$T/notifbin:$PATH" \
	"$HERE/libexec/agent-state-emit" idle >/dev/null 2>&1 \
	|| fail "emit with a notification failed"

_rec=$(cat "$T/run/agent-state/global/8")
# The session is the LAST field, and it must still be the real one.
_got=$(printf '%s
' "$_rec" | { read -r _a _b _c _d _e _f; printf '%s' "$_f"; })
[ "$_got" = "my project" ] \
	|| fail "notification clobbered the session: [$_rec]"
# ... and it must be reachable by name, which is what the strip does.
_found=$(env XDG_RUNTIME_DIR="$T/run" sh -c '
	. "$1/libexec/mux-agent-state.sh"
	mux_agent_state "$(mux_agent_dir global)" "my project"' _ "$HERE")
[ -n "${_found%% *}" ] \
	|| fail "no state after a notification: [$_rec]"
# The BANNER names the session too -- it read "Claude finished: 0".
grep -qF 'my project' "$NLOG" \
	|| fail "banner did not name the session: [$(cat "$NLOG")]"
grep -qxF 'Claude finished: 0' "$NLOG" \
	&& fail "the banner named the window index"

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

# --- a late straggler must not resurrect `working` out of `idle` -----------
# OBSERVED on the `vicus` session, 2026-09-18: its turn finished at 9:09 PM and
# a `working` record was written at 9:12:25, three minutes later, as a FRESH
# transition (the file mtime equalled the new epoch). Stop had already fired.
# Nothing fires after a turn ends, so the session showed a brain glyph for half
# an hour while actually sitting at an empty prompt waiting for input.
#
# This direction is worse than stale-idle: a session that looks BUSY is one you
# deliberately leave alone, so the wait is unbounded.
#
# The rule: `idle` means the turn ENDED, and only a turn-start event may leave
# it. A heartbeat caller (PostToolUse, SubagentStop, a post-turn recap) passes
# --beat and may refresh an existing `working`, never create one.
mkdir -p "$T/lateb"
cat >"$T/lateb/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*window_index*session_name*) printf '0 vicus
' ;;
*mux-notify-always*)         printf '
' ;;
*pane_active*)               printf '1
' ;;
esac
exit 0
EOF
chmod +x "$T/lateb/tmux"
emit() {
	env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%30 \
	PATH="$T/lateb:$PATH" "$HERE/libexec/agent-state-emit" "$@" \
	>/dev/null 2>&1
}
recstate() { cut -d' ' -f1 <"$T/run/agent-state/global/30"; }

rm -f "$T/run/agent-state/global"/*
# The turn ends.
agent_rec "$T/run/agent-state/global/30" idle %30 100 vicus
# A straggler fires. WITHOUT the flag this is the bug, and it is still allowed,
# because an old hooks.json calls it exactly that way and must keep working.
emit working
[ "$(recstate)" = working ] \
	|| fail "a bare 'working' should still be honoured (compatibility)"

# WITH the flag it must be refused: the turn is over.
agent_rec "$T/run/agent-state/global/30" idle %30 100 vicus
emit working --beat
[ "$(recstate)" = idle ] \
	|| fail "--beat resurrected 'working' out of 'idle'"
# ... and the record is untouched, not rewritten with a new epoch.
_ep=$(cut -d' ' -f4 <"$T/run/agent-state/global/30")
[ "$_ep" = 100 ] || fail "--beat rewrote the epoch: [$_ep]"

# It must still REFRESH an agent that is genuinely working.
agent_rec "$T/run/agent-state/global/30" working %30 100 vicus
emit working --beat
[ "$(recstate)" = working ] \
	|| fail "--beat dropped a live 'working'"

# And `blocked` -> `working` is a LEGITIMATE promotion: you approved a
# permission prompt and the tool ran. Scoped to idle, nothing wider.
agent_rec "$T/run/agent-state/global/30" blocked %30 100 vicus
emit working --beat
[ "$(recstate)" = working ] \
	|| fail "--beat blocked a legitimate blocked->working"

# Flag order must not matter.
agent_rec "$T/run/agent-state/global/30" idle %30 100 vicus
emit --beat working
[ "$(recstate)" = idle ] || fail "flag order changed the outcome"
rm -f "$T/run/agent-state/global"/*
st %2 blocked 'my project'
st %3 blocked zulu

pass
