#!/bin/sh
# test/mux-ls.t - `mux ls` and `mux reload`, the last two untested verbs, plus
# mux_agent_state_glyph, which only `ls` and the picker call.
#
# `ls` is how you read the whole context at a glance, so the GLYPH mapping is
# the contract: it comes from mux-agent-state.sh, the single source the status
# strip also uses, and the two must not drift. A wrong glyph here is a session
# reported calm when it needs you.
#
# `reload` iterated partitions with `for _s in $(mux_ctx_partitions)`, which
# word-splits. That producer emits one name per LINE and a partition is a
# filename stem, so `my work.partition` became two servers that do not exist
# while the real one was skipped. Fifth instance of that class in this package;
# the earlier four were session names. mux-themes had the same line, and
# _save_match_layout had it over layout stems.
set -eu
_name=mux-ls
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/proj" "$T/run/agent-state/global"
XDG_RUNTIME_DIR=$T/run; export XDG_RUNTIME_DIR

LIVE=$T/live; SRC=$T/srclog
export LIVE SRC
: >"$SRC"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
# -L SOCKET is recorded so reload's reach is observable per partition.
_sock=default
case "$1" in -L) _sock=$2; shift 2 ;; esac
case "$*" in
list-sessions*)
	[ -s "$LIVE" ] || exit 1
	while IFS= read -r _n; do
		printf '%s: 1 windows (created Mon Jan  1 00:00:00 2026)\n' "$_n"
	done <"$LIVE" ;;
source-file*) printf 'source %s\n' "$_sock" >>"$SRC" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/global.partition"

mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
		XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" "$@" ) 2>&1
}

# --- an empty context says so, and exits 0 ------------------------------
: >"$LIVE"
_rc=0; _o=$(mux ls) || _rc=$?
[ "$_rc" -eq 0 ] || fail "ls on an empty context exited $_rc"
case $_o in
*"no sessions"*) ;;
*) fail "ls did not report an empty context: [$_o]" ;;
esac

# --- the glyph per state, from the single shared source -----------------
# Same mapping the strip uses. A session with no tracked agent gets the
# no-agent glyph rather than being omitted or blank.
printf 'blocked\nworking\nidle\nbare\n' >"$LIVE"
agent_rec "$T/run/agent-state/global/1" blocked %1 100 blocked
agent_rec "$T/run/agent-state/global/2" working %2 100 working
agent_rec "$T/run/agent-state/global/3" idle    %3 100 idle
_o=$(mux ls)
glyph_of() { printf '%s\n' "$_o" | awk -v s="$1:" '$2==s{print $1; exit}'; }
[ "$(glyph_of blocked)" = '⚠️' ] \
	|| fail "blocked glyph is [$(glyph_of blocked)]"
[ "$(glyph_of working)" = '🧠' ] \
	|| fail "working glyph is [$(glyph_of working)]"
[ "$(glyph_of idle)" = '✅' ] || fail "idle glyph is [$(glyph_of idle)]"
[ "$(glyph_of bare)" = '⚫' ] \
	|| fail "a session with no agent should get the none glyph, got
[$(glyph_of bare)]"
# Every live session is listed exactly once.
[ "$(printf '%s\n' "$_o" | grep -c .)" -eq 4 ] \
	|| fail "ls listed $(printf '%s\n' "$_o" | grep -c .) lines, want 4"

# --- a session name containing a SPACE survives ls ---------------------
printf 'my project\n' >"$LIVE"
agent_rec "$T/run/agent-state/global/4" working %4 100 'my project'
_o=$(mux ls)
case $_o in
*"my project:"*) ;;
*) fail "a spaced session name did not survive ls: [$_o]" ;;
esac
printf '%s\n' "$_o" | grep -q '🧠' \
	|| fail "the spaced session lost its glyph: [$_o]"

# --- reload reaches EVERY partition, including one with a space --------
# The bug: `for _s in $(mux_ctx_partitions)` split `my work` into two servers
# that do not exist, and never reached the real one.
mkdir -p "$T/conf/tmux"
printf '# tmux.conf\n' >"$T/conf/tmux/tmux.conf"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/my work.partition"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/other.partition"
printf 'alpha\n' >"$LIVE"
: >"$SRC"
_o=$( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
	XDG_CONFIG_HOME="$T/conf" XDG_RUNTIME_DIR="$T/run" \
	MUX_DIR="$T/conf" MUX_CACHE="$T/cache" "$HERE/bin/mux" reload 2>&1 )
grep -qx 'source my work' "$SRC" \
	|| fail "reload never reached the spaced partition: [$(cat "$SRC")]"
grep -qx 'source my' "$SRC" \
	&& fail "reload split the partition name into a phantom server 'my'"
grep -qx 'source other' "$SRC" \
	|| fail "reload skipped a plain partition: [$(cat "$SRC")]"
case $_o in
*reloaded*) ;;
*) fail "reload did not report what it did: [$_o]" ;;
esac

# --- reload with no tmux.conf refuses, loudly --------------------------
rm -f "$T/conf/tmux/tmux.conf"
_rc=0; _o=$( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
	XDG_CONFIG_HOME="$T/conf" XDG_RUNTIME_DIR="$T/run" \
	MUX_DIR="$T/conf" MUX_CACHE="$T/cache" "$HERE/bin/mux" reload 2>&1 ) \
	|| _rc=$?
[ "$_rc" -ne 0 ] || fail "reload with no tmux.conf exited 0"
case $_o in
*"no tmux.conf"*) ;;
*) fail "the refusal did not name the missing file: [$_o]" ;;
esac

pass
