#!/bin/sh
# mux-views.sh - VIEW TENSION: what happens when two clients of different sizes
# are attached to one tmux server. Sourced by mux-views (the verb and the status
# chip); functions only.
#
# tmux sizes a window to ONE client, and which one is a server option. With more
# than one client attached at different dimensions there is no size that suits
# both, so something has to give -- and by default what gives is stability: the
# window follows whichever client touched it last, so cycling sessions drags
# every window between two sizes and every mux layout is re-pinned each time.
# That is the "why does it redraw when I switch" question this answers.
#
# It is a live, transient condition -- it appears when a second client attaches
# and vanishes when it leaves -- which is why it belongs on the status bar and
# not only in an audit you have to remember to run.
#
# TWO INDEPENDENT FACTS, and conflating them is what makes this confusing:
#
#   1. Is there tension, and WHICH SIDE of it is this view on? (am I the one
#      being clipped, the one with dead space, or the one setting the size)
#   2. What MODE is resolving it -- and that is a choice, not fate.
#
# The modes are mux's names for tmux's window-size, because "latest / smallest
# / largest" describes tmux's ALGORITHM while these describe the OUTCOME you
# get:
#
#   auto   (latest)    the window follows the last client to use it. Every view
#                      is correct for whoever is looking, and the price is that
#                      it moves. tmux's default.
#   floor  (smallest)  every window fits the SMALLEST client. Stable, and no
#                      view is ever clipped; a bigger client carries dead rows.
#   ceil   (largest)   every window fits the LARGEST client. Stable, and the big
#                      view is perfect; a smaller client sees a clipped window.
#
# No mode is correct in general. floor and ceil each buy stability with
# something, and which something depends on whether the small client is a
# forgotten ssh window or the one you are typing into.

MUX_VIEW_MODES='auto floor ceil'

# tmux, addressed at the right SERVER. Inside a session $TMUX already names it,
# so a bare tmux is correct AND cheap -- which matters, because the status chip
# runs this every status-interval. Outside one there is nothing to inherit, so
# the caller resolves its partition and sets MUX_VIEW_SOCKET; without that a
# partitioned setup would silently report on tmux's default socket instead of
# its own, and answer confidently about the wrong server.
_vt() {
	if [ -z "${TMUX:-}" ] && [ -n "${MUX_VIEW_SOCKET:-}" ]; then
		tmux -L "$MUX_VIEW_SOCKET" "$@"
	else
		tmux "$@"
	fi
}

# mux_view_mode -> the mode in mux's vocabulary, from tmux's window-size.
mux_view_mode() {
	case $(_vt show-options -gv window-size 2>/dev/null || echo latest) in
	smallest) printf floor ;;
	largest)  printf ceil ;;
	latest)   printf auto ;;
	*)        printf auto ;;   # manual, or a tmux that has grown a new one
	esac
}

# mux_view_mode_set MODE -> apply it. Rejects an unknown name rather than
# handing tmux a value it will refuse less legibly.
mux_view_mode_set() {   # <auto|floor|ceil>
	case $1 in
	auto)  _wz=latest ;;
	floor) _wz=smallest ;;
	ceil)  _wz=largest ;;
	*) echo "mux: unknown view mode: $1 (want: $MUX_VIEW_MODES)" >&2
	   return 2 ;;
	esac
	_vt set-option -g window-size "$_wz" 2>/dev/null || {
		echo "mux: could not set window-size" >&2; return 1; }
}

# mux_view_clients -> "NAME WIDTHxHEIGHT SESSION IDLE_SECONDS" per attached
# client, one per line. The raw material for everything below.
mux_view_clients() {
	# One `date` for the whole list, not one per client: every idle age is
	# then measured from the same instant, which is also the cheaper way
	# round for something the status bar runs every interval.
	_now=$(date +%s)
	# Built in two pieces: a backslash-newline inside SINGLE quotes is a
	# literal backslash, not a continuation, so splitting the format string
	# that way silently corrupts it and every field shifts.
	_vf='#{client_name} #{client_width}x#{client_height}'
	_vf="$_vf #{client_session} #{client_activity}"
	_vt list-clients -F "$_vf" 2>/dev/null \
	| while read -r _n _d _s _a; do
		[ -n "${_n:-}" ] || continue
		case ${_a:-} in
		''|*[!0-9]*) _idle=0 ;;
		*) _idle=$((_now - _a)) ;;
		esac
		printf '%s %s %s %s\n' "$_n" "$_d" "$_s" "$_idle"
	done
}

# mux_view_sizes -> each DISTINCT client size, one per line. Tension is exactly
# "more than one line here": it is about the set of sizes, not the number of
# clients, so three clients that agree are no tension at all.
mux_view_sizes() {
	mux_view_clients | awk '{print $2}' | LC_ALL=C sort -u | grep . || true
}

# mux_view_tension -> 0 when two or more DISTINCT sizes are attached.
mux_view_tension() {
	[ "$(mux_view_sizes | grep -c .)" -gt 1 ]
}

# Which side of the tension a client is on, as one word. Compares the client to
# the WINDOW it is currently showing, because that is the consequence you can
# actually see:
#
#   clipped  the window is taller/wider than the client -- part of it is off
#            screen. The bad one, and the reason ceil is not a free win.
#   slack    the window is smaller than the client -- dead space. Harmless, but
#            it is why floor costs something.
#   fit      the window matches; this client is the one setting the size.
#
# Empty when it cannot be determined (no such client, no current window).
mux_view_side() {   # <client-name>
	_cs=$(_vt display-message -c "$1" -p \
		'#{client_width}x#{client_height} #{window_width}x#{window_height}' \
		2>/dev/null || true)
	case $_cs in
	*x*' '*x*) ;;
	*) return 0 ;;
	esac
	_cw=${_cs%%x*}
	_ch=${_cs#*x}; _ch=${_ch%% *}
	_ww=${_cs##* }; _ww=${_ww%%x*}
	_wh=${_cs##*x}
	case $_cw$_ch$_ww$_wh in *[!0-9]*) return 0 ;; esac
	if [ "$_wh" -gt "$_ch" ] || [ "$_ww" -gt "$_cw" ]; then
		printf clipped
	elif [ "$_wh" -lt "$_ch" ] || [ "$_ww" -lt "$_cw" ]; then
		printf slack
	else
		printf fit
	fi
}
