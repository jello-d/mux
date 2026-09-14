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
*set-option*window-size*)         printf '%s\n' "${*##* }" >"$OPT" ;;
*list-clients*)                   cat "$CLIENTS" ;;
# The probe: client size, window size and the mode in one round trip. The
# mode comes from $OPT so a set-option above is visible to the next read.
*client_width*window_width*window-size*status*)
        printf '%s %s on\n' "$(cat "$WINSZ")" "$(cat "$OPT")" ;;
*"display-message -p"*)           printf '/dev/pts/0\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'latest\n' >"$OPT"
printf '161x64 161x63' >"$WINSZ"
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
tense
_o=$(views); has "$_o" "tension" "two different sizes did not read as tension"

# --- the chip is ALWAYS drawn ----------------------------------------------
# Fixed furniture at the right edge: the bar must not change width as tension
# comes and goes, and the MODE stays legible when nothing is contending -- a
# floor pinned last week and forgotten is otherwise invisible until it
# surprises you.
calm
_o=$(views --chip /dev/pts/0)
[ -n "$_o" ] || fail "the chip vanished when calm; it is fixed furniture"
has "$_o" "range=user|v:" "chip: not clickable (no range tag)"
_v=$(printf '%s' "$_o" | sed 's/#\[[^]]*\]//g' | tr -d '\n')
[ "$(printf '%s' "$_v" | wc -m)" -eq 1 ] \
        || fail "the chip must be exactly ONE column: [$_v]"

# --- SHAPE carries control: the mode you chose ----------------------------
# The glyphs are the mathematical floor and ceiling symbols, so the picture is
# the name; auto is the one that moves.
glyph() { views --chip /dev/pts/0 | sed 's/#\[[^]]*\]//g' | tr -d '\n'; }
for _pair in 'latest ✱' 'smallest ┻' 'largest ┳'; do
        printf '%s\n' "${_pair%% *}" >"$OPT"
        [ "$(glyph)" = "${_pair##* }" ] || fail \
                "window-size ${_pair%% *} wants ${_pair##* }, drew $(glyph)"
done
# An unknown window-size (tmux's `manual`, or a future one) must still draw
# something legible rather than an empty cell.
printf 'manual\n' >"$OPT"
[ "$(glyph)" = "✱" ] || fail "an unknown window-size broke the glyph"
printf 'latest\n' >"$OPT"

# --- COLOUR carries render: what is happening to THIS view ----------------
# Four states, four colours, and the shape must not move between them: that
# separation is the whole design.
style() { views --chip /dev/pts/0 | grep -o 'fg=colour[0-9]*' | head -1; }
calm
[ "$(style)" = "fg=colour240" ] || fail "calm: wrong colour ($(style))"
[ "$(glyph)" = "✱" ] || fail "calm changed the SHAPE; only colour may move"

tense
printf '161x64 161x63' >"$WINSZ"          # window == client minus status: fit
[ "$(style)" = "fg=colour255" ] || fail "fit: wrong colour ($(style))"

printf '161x64 161x50' >"$WINSZ"          # window SMALLER: dead rows
[ "$(style)" = "fg=colour214" ] || fail "slack: wrong colour ($(style))"
no_has "$(views --chip /dev/pts/0)" "bg=colour202" \
        "slack is harmless; it must not wear the alarm"

printf '161x56 161x63' >"$WINSZ"          # window BIGGER: content off screen
has "$(views --chip /dev/pts/0)" "bg=colour202" \
        "clipped must wear the caution colour -- it is the one that costs you"
[ "$(glyph)" = "✱" ] || fail "clipped changed the SHAPE; only colour may move"
printf '161x64 161x63' >"$WINSZ"

# A client's HEIGHT includes its status line(s), and the window gets what is
# left. Comparing against the RAW height made every view read as one row of
# slack -- including the client actually setting the size -- which is invisible
# until two differently-sized clients are put side by side and both come back
# the same.
tense
printf '161x64 161x63' >"$WINSZ"
[ "$(style)" = "fg=colour255" ] \
        || fail "client 64 showing a 63-row window is FIT, not $(style)"

# --- an explicit MUX_VIEW_SOCKET WINS over the resolved partition ----------
# Overwriting it made the variable look honoured while being ignored, so a
# caller aiming at one server was silently answered about another.
: >"$LOG"
env -u TMUX -u MUX_SHARE PATH="$T/bin:$PATH" MUX_DIR="$T/conf" \
        MUX_VIEW_SOCKET=probe "$HERE/libexec/mux-views" --chip /dev/pts/0 \
        >/dev/null 2>&1 || true
has "$(cat "$LOG")" "-L probe" "an explicit MUX_VIEW_SOCKET was ignored"

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
