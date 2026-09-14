#!/bin/sh
# test/mux-views.t - VIEW TENSION: two clients of different sizes on one server.
#
# tmux sizes a window to ONE client, so with two attached at different
# dimensions there is no size that suits both. By default the window follows
# whichever client used it last, which means every window resizes as you cycle
# sessions and every mux layout is re-pinned each time -- the "why did that
# redraw" that turned out to be a forgotten ssh window still attached at a
# different height.
#
# The two facts are independent and the whole design turns on not conflating
# them: is there tension and WHICH SIDE is this view on, versus what MODE is
# resolving it. So they are tested independently.
#
# tmux is stubbed; the sizes it reports are the input to every case, so no
# server, no clients and no real geometry are involved.
set -eu
_name=mux-views
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin"
CLIENTS=$T/clients            # what list-clients reports
WINSZ=$T/winsz                # "CWxCH WWxWH" for display-message -c
OPT=$T/windowsize             # the window-size option's value
LOG=$T/log
export CLIENTS WINSZ OPT LOG
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LOG"
case "$*" in
*"show-options -gv window-size"*) cat "$OPT" ;;
*set-option*window-size*)         printf '%s\n' "${*##* }" >"$OPT" ;;
*list-clients*)                   cat "$CLIENTS" ;;
*client_width*x*client_height*window_width*) cat "$WINSZ" ;;
*"display-message -p"*)           printf '/dev/pts/0\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'latest\n' >"$OPT"
printf '161x64 161x64\n' >"$WINSZ"
: >"$LOG"

# One client per line: NAME WxH SESSION ACTIVITY(epoch)
calm() { printf '/dev/pts/0 161x64 alpha 100\n/dev/pts/1 161x64 bravo 100\n' \
	>"$CLIENTS"; }
tense() { printf '/dev/pts/0 161x64 alpha 100\n/dev/pts/1 161x56 alpha 100\n' \
	>"$CLIENTS"; }

views() {
	env -u TMUX -u MUX_SHARE PATH="$T/bin:$PATH" MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/libexec/mux-views" "$@" 2>&1
}
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in [$1]" ;; esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in [$1]" ;; esac; }

# --- tension is about the set of SIZES, not the number of clients ----------
# Three clients that agree are not tension; two that disagree are.
calm
_o=$(views); has "$_o" "no tension" "two same-size clients read as tension"
_o=$(views --chip /dev/pts/0)
[ -z "$_o" ] || fail "the chip must be EMPTY when there is no tension: [$_o]"

tense
_o=$(views); has "$_o" "tension" "two different sizes did not read as tension"
_o=$(views --chip /dev/pts/0)
[ -n "$_o" ] || fail "no chip drawn under tension"

# --- the chip carries BOTH facts -------------------------------------------
_v=$(printf '%s' "$_o" | sed 's/#\[[^]]*\]//g')
has "$_v" "2" "chip: no count of the sizes in tension"
has "$_v" "auto" "chip: no mode"
has "$_o" "range=user|v:" "chip: not clickable (no range tag)"

# --- WHICH SIDE this view is on --------------------------------------------
# Compared against the WINDOW it is showing, because that is the consequence
# you can see. `clipped` is the one that costs you something invisible -- part
# of the window is off screen -- so it alone gets the caution colours.
printf '161x64 161x64\n' >"$WINSZ"       # window matches the client
_o=$(views --chip /dev/pts/0)
no_has "$_o" "bg=colour202" "a fitting view wore the caution colour"

printf '161x64 161x55\n' >"$WINSZ"       # window SMALLER: dead rows
_o=$(views --chip /dev/pts/0)
has "$(printf '%s' "$_o" | sed 's/#\[[^]]*\]//g')" "▾" "slack: no marker"
no_has "$_o" "bg=colour202" "slack is harmless; it must not shout"

printf '161x55 161x64\n' >"$WINSZ"       # window BIGGER: clipped, off screen
_o=$(views --chip /dev/pts/0)
has "$(printf '%s' "$_o" | sed 's/#\[[^]]*\]//g')" "▴" "clipped: no marker"
has "$_o" "bg=colour202" "clipped must wear the caution colour"
printf '161x64 161x64\n' >"$WINSZ"

# --- the MODE is mux's vocabulary over tmux's window-size ------------------
# auto/floor/ceil name the OUTCOME; latest/smallest/largest name tmux's
# algorithm. The mapping is the only place the two meet.
for _pair in 'latest auto' 'smallest floor' 'largest ceil'; do
	printf '%s\n' "${_pair%% *}" >"$OPT"
	_o=$(views --chip /dev/pts/0 | sed 's/#\[[^]]*\]//g')
	has "$_o" "${_pair##* }" \
		"window-size ${_pair%% *} should read as ${_pair##* }"
done
# An unknown window-size (tmux's `manual`, or a future one) must not crash or
# invent a mode -- it reports as auto rather than leaving the chip malformed.
printf 'manual\n' >"$OPT"
_o=$(views --chip /dev/pts/0 | sed 's/#\[[^]]*\]//g')
has "$_o" "auto" "an unknown window-size broke the chip"

# --- setting the mode writes the tmux name, not mux's ----------------------
for _pair in 'auto latest' 'floor smallest' 'ceil largest'; do
	printf 'latest\n' >"$OPT"; : >"$LOG"
	views "${_pair%% *}" >/dev/null
	has "$(cat "$LOG")" "window-size ${_pair##* }" \
		"mux views ${_pair%% *} did not set ${_pair##* }"
done

# --- `next` cycles, which is what clicking the chip does ------------------
printf 'latest\n' >"$OPT"
views next >/dev/null; [ "$(cat "$OPT")" = smallest ] \
	|| fail "next from auto should reach floor, got $(cat "$OPT")"
views next >/dev/null; [ "$(cat "$OPT")" = largest ] \
	|| fail "next from floor should reach ceil, got $(cat "$OPT")"
views next >/dev/null; [ "$(cat "$OPT")" = latest ] \
	|| fail "next from ceil should wrap to auto, got $(cat "$OPT")"

# --- refusals --------------------------------------------------------------
_o=$(views nosuchmode) && fail "an unknown mode should exit non-zero"
has "$_o" "usage" "an unknown mode gave no usage"
_o=$(views --detach /dev/pts/99) && fail "detaching an unknown client succeeded"
has "$_o" "no such client" "detaching an unknown client gave no reason"
# ... and a real one is passed through to tmux.
: >"$LOG"
views --detach /dev/pts/1 >/dev/null || fail "detaching a real client failed"
has "$(cat "$LOG")" "detach-client -t /dev/pts/1" "detach did not reach tmux"

pass
