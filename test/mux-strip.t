#!/bin/sh
# test/mux-strip.t - agent-state-render, the status-right session strip.
#
# The largest file in the tree and, until now, the only substantial one with no
# test at all. Its interesting behaviour is GRACEFUL REDUCTION: the strip is
# measured against status-right-length and, when the full chips overflow, it
# degrades in tiers rather than letting tmux truncate it blind --
#
#   full chips -> drop the age -> fold agentless runs -> window around the
#   current session with edge counts -> a bare "needs-you count · total"
#
# with ONE invariant across all of them: a session that needs you is never
# silently dropped. It stays a chip, becomes a caution-marked edge count, or
# survives in the summary count. Blind truncation would drop whatever fell off
# the right, which could be exactly that session -- which is why the tiers
# exist.
#
# The budgets here are not hardcoded widths. The test sweeps the whole range
# and asserts the LADDER (each tier is reachable, and reduction is monotonic)
# plus the invariant AT EVERY WIDTH, so it pins the contract rather than the
# current arithmetic and survives a chip gaining a character.
set -eu
_name=mux-strip
. "$(dirname "$0")/lib.sh"
. "$HERE/libexec/mux-agent-state.sh"      # the glyph constants

mkdir -p "$T/bin" "$T/run/agent-state/global"
SESSIONS=$T/sessions
PANES=$T/panes
export SESSIONS PANES
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*) cat "$SESSIONS" ;;
*list-panes*)    cat "$PANES" ;;
*show-options*)  printf '\n' ;;
# The strip draws the view indicator at its right edge, so the probe behind
# it has to answer deterministically or the tail would vary run to run.
# One client, window matching it: calm, mode auto.
*list-clients*)  printf '/dev/pts/0 161x64 alpha 1\n' ;;
*client_width*)  printf '161x64 161x63 latest on\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

printf 'alpha\nbravo\ncharlie\ndelta\n' >"$SESSIONS"
printf '%%1\n%%2\n%%3\n' >"$PANES"
# "state session window pane epoch notif-id"; epoch 0 keeps ages stable/large.
st() { printf '%s %s 0 %s 1 %s\n' "$2" "$3" "$1" "${4:-}" \
	>"$T/run/agent-state/global/${1#%}"; }
st %1 blocked alpha
st %2 working delta
# bravo and charlie have no agent at all -- the fold candidates.

# render CURRENT BUDGET -> the strip, tmux format escapes and all.
render() {
	env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" \
		MUX_STRIP_WIDTH="$2" PATH="$T/bin:$PATH" \
		"$HERE/libexec/agent-state-render" "$1" testclient 2>/dev/null
}
# The VISIBLE text: tmux #[...] directives carry no display width.
vis() { printf '%s' "$1" | sed 's/#\[[^]]*\]//g'; }
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in [$(vis "$1")]" ;;
	esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in [$(vis "$1")]" ;;
	esac; }

# --- the widest tier: every session, with its age -------------------------
_o=$(vis "$(render delta 400)")
for _s in alpha bravo charlie delta; do
	has "$_o" "$_s" "full strip: missing $_s"
done
has "$_o" "$MUX_GLYPH_BLOCKED" "full strip: no blocked glyph"
# fmt_age renders a fixed 3-col field; epoch 1 pins it at the 99h ceiling.
# NOT a bare "d" -- that matches the "d" in "delta" and proves nothing.
case $_o in *99h*) ;; *) fail "full strip: no age field in [$_o]" ;; esac

# --- the narrowest tier: a bare count -------------------------------------
_o=$(vis "$(render delta 6)")
no_has "$_o" alpha "summary: still naming sessions"
has "$_o" "4" "summary: lost the session total"
has "$_o" "$MUX_GLYPH_BLOCKED" "summary: dropped the needs-you count"

# --- ONE sweep: the invariant at every width, and every tier reachable ----
# Dense across the range where the tiers actually change, plus a few wide
# samples. Swept rather than spot-checked because the boundaries are
# arithmetic, and a sample would sail straight past a hole between two tiers.
#
# Tier discrimination is ORDERED and uses marks that cannot occur otherwise:
# `·2·` is the fold, `‹`/`›` the window edges, `99h` the age field.
# Testing for a bare "d" as the age marker matched the "d" in "delta", which is
# how this first passed while proving nothing.
_saw_age=0 _saw_noage=0 _saw_fold=0 _saw_edge=0 _saw_sum=0
_check() {
	_r=$(vis "$(render delta "$1")")
	[ -n "$_r" ] || fail "width $1: empty strip"
	case $_r in
	*"$MUX_GLYPH_BLOCKED"*|*alpha*) ;;
	*) fail "width $1: the blocked session vanished -- [$_r]" ;;
	esac
	case $_r in
	*"·2·"*)   _saw_fold=1 ;;
	*"‹"*|*"›"*) _saw_edge=1 ;;
	*99h*)                 _saw_age=1 ;;
	*alpha*)               _saw_noage=1 ;;
	*)                     _saw_sum=1 ;;
	esac
}
_w=1
while [ "$_w" -le 100 ]; do _check "$_w"; _w=$((_w + 1)); done
for _w in 140 200 400; do _check "$_w"; done

[ "$_saw_age"   -eq 1 ] || fail "the full (aged) tier is never selected"
[ "$_saw_noage" -eq 1 ] || fail "the drop-the-age tier is never selected"
[ "$_saw_fold"  -eq 1 ] || fail "the fold-agentless tier is never selected"
[ "$_saw_edge"  -eq 1 ] || fail "the window tier is never selected"
[ "$_saw_sum"   -eq 1 ] || fail "the summary tier is never selected"

# --- reduction is MONOTONIC ------------------------------------------------
# A narrower budget must never produce a WIDER strip. Compared on visible
# length, which is what the budget is denominated in.
_prev=0
_w=1
while [ "$_w" -le 400 ]; do
	_len=$(printf '%s' "$(vis "$(render delta "$_w")")" | wc -m | tr -d ' ')
	[ "$_len" -ge "$_prev" ] || fail \
		"width $_w produced a shorter strip than a narrower budget"
	_prev=$_len
	_w=$((_w + 40))
done

# --- the view indicator is FIXED FURNITURE at the right edge --------------
# It is drawn by this script rather than as its own status-left segment so its
# width comes out of the SAME budget the tiers spend -- a second #() appended
# by tmux would be invisible to them and would silently push the strip past
# status-right-length. Two things follow, and both are contract:
#
#   it is present at EVERY width, including the summary floor, so the bar never
#   changes width as tension comes and goes; and
#   reduction never eats it, because it is not a chip that may be dropped.
#
# (Below about ten columns the summary tier is already at its own floor and
# cannot compress further, so the total exceeds a budget that small. That is
# the pre-existing floor, not something the indicator introduced.)
_w=400
while [ "$_w" -ge 10 ]; do
	_r=$(vis "$(render delta "$_w")")
	case $_r in
	*"⇕"*) ;;
	*) fail "width $_w: the view indicator was dropped -- [$_r]" ;;
	esac
	_w=$((_w - 1))
done
# ... and it is the LAST thing on the strip, after a separator.
_edge=$(vis "$(render delta 400)")
case $_edge in
*"│ ⇕") ;;
*) fail "the indicator is not at the right edge: [$_edge]" ;;
esac

# --- the current session is the one marked ---------------------------------
_o=$(render alpha 400)
case $_o in *"underscore"*) ;; *) fail "no current-session chip drawn" ;; esac

# --- `mux hide` drops a session from THIS client's strip only --------------
mkdir -p "$T/run/mux-exclude"
printf 'charlie\n' >"$T/run/mux-exclude/testclient"
_o=$(vis "$(render delta 400)")
no_has "$_o" charlie "hidden session still on the strip"
has "$_o" bravo "hiding one session dropped another"
# ... and another client is unaffected: the set is keyed per client.
_o2=$(vis "$(env -u TMUX XDG_RUNTIME_DIR="$T/run" MUX_STRIP_WIDTH=400 \
	PATH="$T/bin:$PATH" "$HERE/libexec/agent-state-render" delta other)")
has "$_o2" charlie "hiding leaked to another client"
rm -f "$T/run/mux-exclude/testclient"

# --- a dead pane's state file is pruned ------------------------------------
# A killed agent never fires its Stop hook, so nothing else removes these; a
# phantom would keep reporting state for a pane that is gone.
st %9 blocked ghost
[ -f "$T/run/agent-state/global/9" ] || fail "setup: no phantom to prune"
render delta 400 >/dev/null
[ -f "$T/run/agent-state/global/9" ] \
	&& fail "a state file for a dead pane survived the render"
# ... and a LIVE pane's file is untouched.
[ -f "$T/run/agent-state/global/1" ] || fail "pruned a live pane's state"

pass
