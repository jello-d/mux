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

# mux_view_mode -> the mode in mux's vocabulary. Read through the probe rather
# than its own show-options call: the probe already fetches window-size (it is
# a real format), and a second reader would be a second place for the same fact
# to be derived -- and to disagree.
mux_view_mode() {   # [client-name]
	mux_view_probe "${1:-}"
	printf '%s' "$MUX_VIEW_MODE"
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
	# The probe cached the OLD mode; anything reading it after this would
	# report the value we just replaced.
	MUX_VIEW_MODE=$1
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

# mux_view_server_tension -> 0 when two or more DISTINCT sizes are attached
# ANYWHERE on this server. Latent: it says a disagreement exists, not that
# anything is currently resolving it. The right question for an audit.
mux_view_server_tension() {
	[ "$(mux_view_sizes | grep -c .)" -gt 1 ]
}

# The distinct sizes contending for the window CLIENT is looking at -- i.e.
# among the clients attached to ITS session.
#
# tmux sizes a window from the clients attached to that window's SESSION, not
# from every client on the server. So two differently-sized clients sitting on
# two different sessions contend over nothing: each window is its own client's
# size and window-size has no second opinion to reconcile. Verified: with one
# client per session, latest/smallest/largest all leave the windows untouched.
mux_view_contenders() {   # [client-name]
	mux_view_probe "${1:-}"
	[ -n "${MUX_VIEW_SESS:-}" ] || { mux_view_sizes; return 0; }
	mux_view_clients \
	| awk -v s="$MUX_VIEW_SESS" '$3 == s { print $2 }' \
	| LC_ALL=C sort -u | grep . || true
}

# mux_view_tension [client] -> 0 when the WINDOW this client is looking at is
# actually contended. Scoped to the window on purpose: the colour half of the
# indicator already describes this view, and testing tension server-wide while
# colouring per-window meant the chip could report contention that changed
# nothing here -- and that the mode glyph sat beside a state the mode could not
# move.
mux_view_tension() {   # [client-name]
	[ "$(mux_view_contenders "${1:-}" | grep -c .)" -gt 1 ]
}

# Everything the chip needs, in ONE round trip: this client's size, the window
# it is currently showing, and the mode. The status bar redraws every interval
# for every client, so each extra tmux call is a cost paid forever --
# and #{window-size} being a real FORMAT is what lets the mode ride along here
# instead of costing a second call to show-options.
#
# Results land in MUX_VIEW_CW/CH/WW/WH and MUX_VIEW_MODE. Probing twice is a
# no-op, so the small readers below can each be called without any of them
# paying for a round trip the first already made.
mux_view_probe() {      # [client-name]
	[ -z "${MUX_VIEW_MODE:-}" ] || return 0
	_pf='#{client_width}x#{client_height}'
	_pf="$_pf #{window_width}x#{window_height} #{window-size} #{status}"
	_pf="$_pf #{client_session}"
	if [ -n "${1:-}" ]; then
		_pr=$(_vt display-message -c "$1" -p "$_pf" 2>/dev/null || true)
	else
		_pr=$(_vt display-message -p "$_pf" 2>/dev/null || true)
	fi
	MUX_VIEW_CW= MUX_VIEW_CH= MUX_VIEW_WW= MUX_VIEW_WH= MUX_VIEW_ST=0
	MUX_VIEW_SESS=
	MUX_VIEW_MODE=auto
	case $_pr in
	*x*' '*x*' '*' '*) ;;
	*) return 0 ;;
	esac
	_a=${_pr%% *}; _rest=${_pr#* }
	_b=${_rest%% *}; _rest=${_rest#* }
	_wz=${_rest%% *}; _rest=${_rest#* }
	# The session is LAST so it may contain spaces (tmux allows it, even if
	# mux-derived names never do) and still be taken whole.
	case $_rest in
	*' '*) _st=${_rest%% *}; MUX_VIEW_SESS=${_rest#* } ;;
	*)     _st=$_rest ;;
	esac
	MUX_VIEW_CW=${_a%%x*}; MUX_VIEW_CH=${_a##*x}
	MUX_VIEW_WW=${_b%%x*}; MUX_VIEW_WH=${_b##*x}
	case $_wz in
	smallest) MUX_VIEW_MODE=floor ;;
	largest)  MUX_VIEW_MODE=ceil ;;
	*)        MUX_VIEW_MODE=auto ;;
	esac
	# Status lines, so the comparison below can take them off the client's
	# height. `status` is on/off or a count.
	case $_st in
	off)   MUX_VIEW_ST=0 ;;
	on)    MUX_VIEW_ST=1 ;;
	[0-9]) MUX_VIEW_ST=$_st ;;
	*)     MUX_VIEW_ST=1 ;;
	esac
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
	mux_view_probe "$1"
	case ${MUX_VIEW_CW:-}${MUX_VIEW_CH:-}${MUX_VIEW_WW:-}${MUX_VIEW_WH:-} in
	''|*[!0-9]*) return 0 ;;
	esac
	# A client's HEIGHT includes its status line(s); the window gets what is
	# left. So a perfectly fitted client is client_height - status, and
	# comparing against the raw height made EVERY view read as one row of
	# slack -- which is exactly what it did, on both clients, until two
	# differently-sized clients were put side by side and both came back the
	# same.
	_eh=$((MUX_VIEW_CH - MUX_VIEW_ST))
	if [ "$MUX_VIEW_WH" -gt "$_eh" ] \
	   || [ "$MUX_VIEW_WW" -gt "$MUX_VIEW_CW" ]; then
		printf clipped
	elif [ "$MUX_VIEW_WH" -lt "$_eh" ] \
	     || [ "$MUX_VIEW_WW" -lt "$MUX_VIEW_CW" ]; then
		printf slack
	else
		printf fit
	fi
}

# --- the one-glyph indicator -----------------------------------------------
# TWO dimensions, TWO channels, assigned by what each is good at:
#
#   SHAPE  carries CONTROL -- the mode, which you chose. A small closed set is
#          exactly what a shape distinguishes well, and the glyphs are the
#          mathematical floor and ceiling symbols, so the picture IS the name.
#   COLOUR carries RENDER  -- what is happening TO this view, which has one
#          genuinely urgent value (clipped). Colour is what eyes catch, and
#          mux already spends its loudest pairing on a blocked agent.
#
# Drawn even when calm, so the bar never changes width and the mode is legible
# at all times: a `floor` pinned last week and forgotten is otherwise invisible
# until it surprises you.
MUX_VIEW_W=1                    # visible columns, for the strip's width budget

mux_view_glyph() {
	mux_view_probe "${1:-}"
	# Box-drawing, not the mathematical floor/ceiling marks: those are
	# thin corner ticks that read as a bare pipe in most terminal fonts,
	# and as each other. Here the BAR is the pin and its POSITION is the
	# bound it pins to -- bar at the bottom is a floor to stand on, bar at
	# the top is a ceiling to hit. auto keeps an arrow, deliberately a
	# different family: it is the one that is not pinned at all.
	# HEAVY box-drawing for the pinned pair: the BAR is the pin and its
	# position is the bound. Both are present in the terminal font itself
	# rather than reached by fallback, so they render at the right metrics.
	#
	# auto is an ASTERISK, not an arrow. Every up-down arrow actually present
	# in a monospace face renders too small to read at a glance, and the
	# bold triangle-headed ones (U+2B65, U+2B81) are in neither DejaVu Sans
	# Mono nor most others -- they arrive from a proportional fallback, at
	# another font's metrics, and are tofu where it is absent. An asterisk's
	# wildcard sense -- any of these, whatever comes last -- happens to be
	# exactly what auto means.
	#
	# The HEAVY asterisk, not the plain one. Measured against DejaVu Sans
	# Mono's own outlines, U+002A is drawn 484 units ABOVE the x-height
	# centre (the typographic raised asterisk), so it floats near the cap
	# line while its neighbours sit mid-cell. U+2731 is 16 units off centre,
	# and being heavy it also reads at the weight of the bars beside it.
	# U+2733/U+2734 centre marginally better but are emoji-capable, so a
	# terminal may give them a width-2 presentation and break the strip's
	# width budget -- not a trade worth ten font units.
	case $MUX_VIEW_MODE in
	floor) printf '\342\224\273' ;;   # U+253B  heavy bar below, stem up
	ceil)  printf '\342\224\263' ;;   # U+2533  heavy bar above, stem down
	*)     printf '\342\234\261' ;;   # U+2731  heavy asterisk: unpinned
	esac
}

# calm | fit | slack | clipped -- the render half, in one word.
mux_view_state() {   # <client-name>
	mux_view_tension "${1:-}" || { printf calm; return 0; }
	_st=$(mux_view_side "${1:-}")
	printf '%s' "${_st:-fit}"
}

# The chip itself: one styled, click-tagged glyph. Composed HERE so the status
# strip and `mux views --chip` cannot disagree about what it looks like.
mux_view_chip() {   # <client-name>
	# clipped is PURE YELLOW on orange, the hazard-stripe pairing, rather
	# than the near-black the blocked-agent chip uses on the same orange.
	# Deliberately NOT sharing that look: the two mean different things and
	# sit a few cells apart, so a shared style would invite reading one as
	# the other. By raw contrast black wins (6.57 vs 2.84 against #ff5f00),
	# but that threshold is for body text; this is one bold glyph, and the
	# job is to be unmistakably an ALARM rather than merely legible.
	case $(mux_view_state "${1:-}") in
	clipped) _vs='#[fg=colour226,bg=colour202,bold]' ;;
	slack)   _vs='#[fg=colour214]' ;;
	fit)     _vs='#[fg=colour255,bold]' ;;
	*)       _vs='#[fg=colour240]' ;;
	esac
	printf '#[range=user|v:mode]%s%s#[default]#[norange]' \
		"$_vs" "$(mux_view_glyph "${1:-}")"
}
