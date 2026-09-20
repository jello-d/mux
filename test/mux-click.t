#!/bin/sh
# test/mux-click.t - the last two files the suite never executed at all:
# libexec/mux-click (status-bar clicks) and libexec/mux-status-banner (the
# centred prefix/zoom banner). Both were measured dark, not assumed so.
#
# mux-click is short and entirely about NOT acting. It receives a tmux range
# tag from MouseDown1Status, and everything it declines to do is a mis-click
# that would otherwise switch you somewhere you did not ask for:
#
#   a tag naming no live session  -> nothing (tmux truncates a range label past
#                                   15 chars, so a tag CAN be a partial name)
#   an unrecognised tag           -> nothing
#   the v: tension chip           -> cycle the view mode, NOT a session switch
#
# mux-status-banner is about IDEMPOTENCE. It rebuilds status-format[0] rather
# than appending, stashing the pristine default on first run, so re-running it
# (every `mux reload`) must not accumulate banners. Appending instead of
# rebuilding would grow the status line on every reload, forever.
set -eu
_name=mux-click
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin"
LOG=$T/log; OPTS=$T/opts
export LOG OPTS
: >"$LOG"; : >"$OPTS"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*switch-client*) printf 'switch %s\n' "$*" >>"$LOG" ;;
"show -gqv "*)
	awk -F'\t' -v k="${*##* }" '$1==k{print $2; exit}' "$OPTS" 2>/dev/null ;;
"set -g "*)
	shift 2; _n=$1; shift; _v=$*
	printf 'set %s\n' "$_n" >>"$LOG"
	# An exact FIELD compare, not a grep pattern: the real option name here
	# is `status-format[0]`, and [0] is a regex character class -- so a
	# grep-based removal silently kept the old line and every read returned
	# the stale first match. A stub that models the tool wrongly is worse
	# than no test; this one produced a confident false failure.
	awk -F'\t' -v k="$_n" '$1 != k' "$OPTS" >"$OPTS.t" 2>/dev/null || :
	mv -f "$OPTS.t" "$OPTS"
	printf '%s\t%s\n' "$_n" "$_v" >>"$OPTS" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

click() {
	: >"$LOG"
	env PATH="$T/bin:$PATH" "$HERE/libexec/mux-click" "$@" 2>&1
	cat "$LOG"
}
opt() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$OPTS" 2>/dev/null; }

# --- a session tag switches, with exact matching -------------------------
# `=NAME` is tmux's exact-match form; without it a click could land on a
# different session that merely shares a prefix.
_o=$(click 's:alpha' '/dev/pts/3')
case $_o in
*"switch-client -c /dev/pts/3 -t =alpha"*) ;;
*) fail "a session click did not switch exactly: [$_o]" ;;
esac

# Without a client, it still switches (the binding may not pass one).
_o=$(click 's:alpha')
case $_o in
*"switch-client -t =alpha"*) ;;
*) fail "a clientless click did not switch: [$_o]" ;;
esac

# --- everything it must DECLINE -----------------------------------------
# Each of these is a mis-click. Landing somewhere would be worse than nothing,
# so the only acceptable outcome is an empty log and a zero exit.
for _bad in '' 's:' 'x:alpha' 'alpha' 'user|s:alpha' '-' 'S:alpha'; do
	_rc=0; _o=$(click "$_bad" '/dev/pts/3') || _rc=$?
	[ "$_rc" -eq 0 ] || fail "tag [$_bad] exited $_rc instead of no-opping"
	[ -z "$_o" ] || fail "tag [$_bad] acted on a mis-click: [$_o]"
done

# --- the v: tension chip cycles the VIEW MODE, not a session -------------
# Clicking it is how the tension is settled without looking up a verb, so it
# must not be mistaken for a session named `v:...`.
mkdir -p "$T/vbin"
cat >"$T/vbin/mux-views" <<'EOF'
#!/bin/sh
printf 'views %s\n' "$*" >>"$LOG"
EOF
chmod +x "$T/vbin/mux-views"
cp "$HERE/libexec/mux-click" "$T/vbin/mux-click"
: >"$LOG"
env PATH="$T/bin:$PATH" "$T/vbin/mux-click" 'v:fit' '/dev/pts/3' >/dev/null 2>&1
grep -qx 'views next' "$LOG" \
	|| fail "the tension chip did not cycle the view mode: [$(cat "$LOG")]"
grep -q 'switch-client' "$LOG" \
	&& fail "the tension chip was treated as a session switch"

# --- the banner is IDEMPOTENT across re-runs ----------------------------
# It rebuilds status-format[0] from a stashed pristine default. Appending
# instead would grow the status line on every `mux reload`, forever.
: >"$OPTS"; : >"$LOG"
printf 'status-format[0]\tPRISTINE\n' >"$OPTS"
banner() { env PATH="$T/bin:$PATH" "$HERE/libexec/mux-status-banner" 2>&1; }
banner || fail "the banner script failed"
[ "$(opt @mux-sf0-default)" = PRISTINE ] \
	|| fail "the pristine default was not stashed: [$(opt @mux-sf0-default)]"
_first=$(opt 'status-format[0]')
case $_first in
PRISTINE*) ;;
*) fail "the rebuild lost the pristine default: [$_first]" ;;
esac
case $_first in
*PREFIX*) ;;
*) fail "the prefix banner is missing: [$_first]" ;;
esac

# Re-run twice more: the value must be IDENTICAL, not accumulated.
banner >/dev/null; banner >/dev/null
[ "$(opt 'status-format[0]')" = "$_first" ] \
	|| fail "re-running accumulated banners:
first: $_first
now:   $(opt 'status-format[0]')"
# ... and the count of banner fragments stays at one.
_n=$(printf '%s' "$(opt 'status-format[0]')" \
	| awk '{ n = gsub(/align=centre/, ""); print n }')
[ "$_n" -eq 1 ] || fail "status-format[0] carries $_n banners, want 1"

# --- the stash is read, not re-captured, once it exists -----------------
# If it re-stashed on every run, the second stash would capture the ALREADY
# BANNERED value and the pristine default would be lost for good.
[ "$(opt @mux-sf0-default)" = PRISTINE ] \
	|| fail "the stash was overwritten with a bannered value:
$(opt @mux-sf0-default)"

pass
