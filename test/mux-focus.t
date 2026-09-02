#!/bin/sh
# test/mux-focus.t - a new session must OPEN on the agent pane. It is the pane
# you built the session to look at, and landing left of it cost a keystroke on
# every single launch. A layout with no agent falls back to the first pane.
#
# tmux is stubbed in $T/bin and hands out incrementing pane ids (%1, %2, ...) so
# the select-pane target identifies WHICH pane was chosen. No server is started.
set -eu
_name=mux-focus
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/layouts" "$T/conf/profiles.d" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)
	# One fresh id per query, so each pane mux creates gets its own.
	_n=$(cat "$PANESEQ" 2>/dev/null || echo 0)
	_n=$((_n + 1)); printf '%s\n' "$_n" >"$PANESEQ"
	printf '%%%s\n' "$_n" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; PANESEQ=$T/seq
export TMUXLOG PANESEQ
PATH=$T/bin:$PATH; export PATH

# go ARGS... -> run mux, then echo the pane it selected.
selected() {
	: >"$TMUXLOG"; : >"$PANESEQ"
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" "$@" ) >/dev/null 2>&1 \
		|| fail "mux $* exited $?"
	awk '/select-pane -t/{p=$NF} END{print p}' "$TMUXLOG"
}

# Ids follow the STUB's query order, not real tmux pane numbering: mux asks for
# a pane id once when it creates the window, then once per pane it builds. So
# for the shipped default (`pane`, `pane agent`, `bottom`) the window takes %1,
# the left pane %2, and the agent %3. What matters is that the id selected at
# the end is the one captured for the AGENT pane, not the first one.
_got=$(selected new --force f1)
[ "$_got" = "%3" ] || fail "default: selected [$_got], want the agent %3"

# --bare runs no agent command, but the agent PANE is still the one to open on.
_got=$(selected --bare new --force f2)
[ "$_got" = "%3" ] || fail "--bare: selected [$_got], want the agent %3"

# `pane <name>` naming an agent profile counts as the agent pane too.
printf 'window w\npane\npane    claude\n' >"$T/conf/layouts/named.layout"
printf 'layout  named\n' >"$T/conf/profiles.d/named.profile"
_got=$(selected go f3 named)
[ "$_got" = "%3" ] || fail "pane claude: selected [$_got], want %3"

# No agent anywhere: fall back to the first pane rather than selecting nothing.
printf 'window w\npane\npane\n' >"$T/conf/layouts/noagent.layout"
printf 'layout  noagent\n' >"$T/conf/profiles.d/noagent.profile"
_got=$(selected go f4 noagent)
[ "$_got" = "%1" ] || fail "no agent: selected [$_got], want the first pane %1"

# An agent in a LATER window takes the window selection with it, so the session
# still opens looking at the agent.
printf 'window one\npane\nwindow two\npane    agent\n' \
	>"$T/conf/layouts/late.layout"
printf 'layout  late\n' >"$T/conf/profiles.d/late.profile"
: >"$TMUXLOG"; : >"$PANESEQ"
( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
	MUX_CACHE="$T/cache" "$HERE/bin/mux" go f5 late ) >/dev/null 2>&1 \
	|| fail "late-agent layout exited $?"
grep -q 'select-pane -t %3' "$TMUXLOG" \
	|| fail "an agent in a later window should still be selected"
grep -q 'select-window -t f5:0' "$TMUXLOG" \
	|| fail "the agent's window should be selected too"

pass
