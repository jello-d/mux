#!/bin/sh
# test/mux-capabilities.t - the handshake that ends version-sniffing.
#
# THE MEASUREMENT THAT MOTIVATED IT. Against a box running an older mux:
#
#   ssh manifold mux agent-list   ->  mux: unknown verb: agent-list   exit 2
#   ssh manifold mux agent-summary ->  idle 5                          exit 0
#
# That box was reachable, healthy, and answering non-zero. Without a handshake
# every cross-version consumer discovers support BY FAILURE, and a fleet part
# way through an upgrade reads as half-broken.
#
# THE WHOLE KNOWN SET IS ENUMERATED, not just what works. A present-only list
# makes absence ambiguous: "this mux does not support it" and "whoever added the
# verb forgot the line" look identical. Declaring everything makes absence mean
# exactly one thing, that this mux predates the capability, and turns "not
# usable right now" into a value rather than a silence.
#
# And that is what makes OMISSION testable, which is the assertion this file
# exists for: every dispatchable verb must appear in the manifest, so a new verb
# nobody classified fails here rather than quietly never being advertised.
set -eu
_name=mux-capabilities
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf"
# No notify-send on PATH, so the `notify` capability has a contextual answer to
# give. The ordinary tools still have to be put back explicitly.
for _c in sed awk grep cut tr head tail wc cat ls id date find sort basename \
          dirname mktemp rm mkdir cp mv readlink; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
printf '#!/bin/sh\nexit 0\n' >"$T/bin/tmux"; chmod +x "$T/bin/tmux"

caps() {
	env -u MUX_SHARE -u TMUX -u MUX_NOTIFY_SEND -u MUX_NOTIFY_CLOSE \
		PATH="$T/bin" MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" capabilities "$@" 2>&1
}
val() { printf '%s\n' "$1" | awk -v k="$2" '$1==k{print $2, $3; exit}'; }

# --- the shape: a version line, then NAME VALUE pairs -------------------
_o=$(caps)
[ "$(printf '%s\n' "$_o" | head -1)" = "mux $(grep '^MUX_VERSION=' \
	"$HERE/bin/mux" | cut -d= -f2)" ] \
	|| fail "the first line must be 'mux <version>', got:
$(printf '%s\n' "$_o" | head -1)"
# Every remaining line is exactly NAME plus one or two fields. A consumer parses
# this with `read -r name value note`, so a stray third shape breaks it.
printf '%s\n' "$_o" | tail -n +2 | while IFS= read -r _l; do
	[ -n "$_l" ] || continue
	_nf=$(printf '%s\n' "$_l" | awk '{print NF}')
	case $_nf in
	2|3) ;;
	*) fail "capability line has $_nf fields, want 2 or 3: [$_l]" ;;
	esac
done

# --- it exits 0 even when a capability is unavailable ------------------
# A pure report. A non-zero exit here would be indistinguishable from the
# transport (see EXIT STATUS), which is the ambiguity this verb removes.
_rc=0; caps >/dev/null 2>&1 || _rc=$?
[ "$_rc" -eq 0 ] || fail "capabilities exited $_rc; it must always answer 0"

# --- the three answer kinds are all present and distinct ---------------
# A version means usable. `unavailable` means implemented but not here.
# `no` means this build does not have it at all. All three are ANSWERS.
[ "$(val "$_o" agent-list)" = "1 " ] \
	|| fail "agent-list should be usable: [$(val "$_o" agent-list)]"
case $(val "$_o" notify) in
*unavailable*) ;;
*) fail "with no notify-send, notify should read unavailable, got
[$(val "$_o" notify)]" ;;
esac
[ "$(val "$_o" attach-only)" = "no " ] \
	|| fail "attach-only is not implemented, so it must read 'no': got
[$(val "$_o" attach-only)]"
# latch IS implemented, but there is no ssh on this stub PATH, so it is the
# other contextual one. `1 unavailable` and `no` must not collapse together:
# one says try again elsewhere, the other says never on this build.
case $(val "$_o" latch) in
*"1 unavailable"*) ;;
*) fail "latch is implemented but has no transport here, so it should read
'1 unavailable': got [$(val "$_o" latch)]" ;;
esac

# ... and a capability that becomes usable says so, rather than staying absent.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/notify-send"
chmod +x "$T/bin/notify-send"
case $(val "$(caps)" notify) in
"1 ") ;;
*) fail "with notify-send present, notify should be usable: got
[$(val "$(caps)" notify)]" ;;
esac
rm -f "$T/bin/notify-send"

# latch reads usable once its transport's program exists. Only the first WORD of
# the template is checked, so the rest being nonsense must not matter.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/myhop"; chmod +x "$T/bin/myhop"
case $(MUX_LATCH_TRANSPORT='myhop -x %h mux go %s' caps | \
	awk '$1=="latch"{print $2, $3}') in
"1 ") ;;
*) fail "with its transport present, latch should be usable: got
[$(MUX_LATCH_TRANSPORT='myhop %h' caps | grep '^latch')]" ;;
esac

# The context seam is the other contextual one: unavailable with no
# context-command configured, usable once there is one.
case $(val "$_o" context) in
*unavailable*) ;;
*) fail "with no context-command, context should read unavailable" ;;
esac
printf 'context-command cc\n' >"$T/conf/config"
case $(val "$(caps)" context) in
"1 ") ;;
*) fail "with a context-command configured, context should be usable" ;;
esac
rm -f "$T/conf/config"

# --- THE OMISSION GUARD -----------------------------------------------
# Every verb the front end dispatches must be classified in the manifest. This
# is the assertion the full enumeration buys: a curated present-only list can
# silently omit a new verb forever, and nothing would ever say so.
_declared=$(caps --all | tail -n +2 | awk '{print $1}' | LC_ALL=C sort -u)

# The two dispatch mechanisms, read from the source rather than from a list kept
# here: an early exec table for the helper verbs, and the main whitelist.
_early=$(awk '/^case \$\{1:-\} in$/,/^esac$/' "$HERE/bin/mux" \
	| grep -oE '^[a-z][a-z-]*\)' | tr -d ')')
# The main block is SPACE indented and the early one is not, so the pattern
# allows either. Getting this wrong found only 18 of 33 verbs, and the count
# floor below is what caught it rather than a silent pass.
_main=$(awk '/^case \$cmd in$/,/^esac$/' "$HERE/bin/mux" \
	| grep -oE '^[[:space:]]+[a-z|-]+\)' \
	| tr -d ' \t)' | tr '|' '\n')
_dispatched=$(printf '%s\n%s\n' "$_early" "$_main" | grep . | LC_ALL=C sort -u)

[ -n "$_dispatched" ] || fail "no verbs were discovered from bin/mux; the
dispatch-table scrape is broken and this guard is proving nothing"
_cnt=$(printf '%s\n' "$_dispatched" | grep -c .)
[ "$_cnt" -ge 25 ] || fail "only $_cnt verbs discovered, expected 30 or more.
The scrape has stopped matching and would pass no matter what is missing"

_missing=$(printf '%s\n' "$_dispatched" | while IFS= read -r _v; do
	[ -n "$_v" ] || continue
	printf '%s\n' "$_declared" | grep -qxF "$_v" || printf '%s\n' "$_v"
done)
[ -z "$_missing" ] || fail "these dispatchable verbs are NOT in the capability
manifest, so nothing declares whether they are a contract or internal:

$_missing

Add each to _cap_manifest in bin/mux as 'contract <n>' or 'internal'."

# The reverse is NOT required: a capability may be a seam rather than a verb
# (notify, context) or a known-but-absent one (latch). But anything declared a
# CONTRACT that is also a verb must actually dispatch, or the handshake
# advertises something a caller cannot invoke.
printf '%s\n' "$_o" | tail -n +2 | while IFS= read -r _l; do
	_cn=${_l%% *}
	case $_cn in
	notify|context) continue ;;            # seams, not verbs
	esac
	# A forward declaration has no verb by definition, and skipping it by
	# VALUE rather than by name means the next one needs no edit here.
	case $_l in
	*' no') continue ;;
	esac
	case " $(printf '%s\n' "$_dispatched" | tr '\n' ' ') " in
	*" $_cn "*) ;;
	*) fail "capabilities advertises '$_cn', which no verb dispatches" ;;
	esac
done

pass
