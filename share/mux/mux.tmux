# mux.tmux -- the REQUIRED mux tmux integration: the status bar (context
# banner, per-host chip, agent-state strip), the feature key bindings, and the
# layout/resize hooks. `source-file` this from your tmux.conf.
#
# Every helper is reached as `mux <verb>` -- the single entry point on PATH, so
# this file carries NO path to mux's internals (mux self-locates its libexec).
# It just needs `mux` on PATH when tmux starts. The mouse chip-click binding
# only fires when `mouse on` is set (mux-opinions.tmux does that, or your own
# config). Feature KEYS are bound in the prefix table, so your prefix choice is
# untouched; rebind any of them AFTER sourcing to change them.

# --- session navigation across mux's own features -------------------------
# Session cycling that SKIPS this client's hidden sessions (mux hide). tmux's
# built-in ( / ) cannot skip, so route through `mux cycle`, which computes the
# explicit next/prev VISIBLE session and switch-client -t's to it. Pass the
# client and its current session; run-shell (foreground) makes the switch
# immediate, and mux cycle stays silent so tmux never pops an output buffer.
bind ( run-shell "mux cycle prev '#{client_name}' '#{client_session}'"
bind ) run-shell "mux cycle next '#{client_name}' '#{client_session}'"

# A there-and-back session pair:
#   prefix b : jump to the session whose agent has been blocked (needs you)
#              LONGEST -- the loudest chip on the strip (mux-next-blocked).
#              Repeat to walk down the urgency order.
#   prefix B : toggle back to the last session (switch-client -l) -- so b takes
#              you to the alert, B brings you home.
bind b run-shell "mux next-blocked '#{client_name}'"
bind B switch-client -l

# Click a session chip (status-right strip) to jump STRAIGHT to it, unlike ( / )
# which step neighbours. agent-state-render tags each chip #[range=user|s:NAME],
# so a click hands mux-click that tag; a hidden session has no chip, no range,
# no press. Anything else on the bar (the window list on the left) keeps the
# default -- switch to the target under the mouse. Needs `mouse on`.
bind -n MouseDown1Status {
  if -F '#{m:s:*,#{mouse_status_range}}' {
    run-shell "mux click '#{mouse_status_range}' '#{client_name}'"
  } {
    switch-client -t =
  }
}

# prefix+r = refresh: unstick a layout that tmux's proportional resize wedged at
# the wrong size (the "half-height pane" glitch). Runs mux-refresh (perturb the
# bottom pane, then re-pin) -- the keyboard replacement for the old drag-the-
# border fix now that pane-resize drag is unbound, and a home for future
# refresh-style fixes as new glitches surface.
# prefix+R = the bigger hammer: REBUILD the bottom pane (break out + rejoin) to
# clear a stuck RENDER state a perturb cannot -- e.g. tmux drawing a border in
# reverse video. Content preserved, focus restored.
bind r run-shell "mux refresh"
bind R run-shell "mux refresh --force"

# --- colour themes ---------------------------------------------------------
# THE COLOUR IS NOT THE BOUNDARY (see mux-style). It is cosmetic: a default that
# any session may override with a `theme` directive in its layout. A theme names
# up to six styles -- the bar (status-style/message-style), the current-window
# chip (window-status-current-style), the ACTIVE pane border (pane-active-
# border-style), the INACTIVE pane borders (pane-border-style), the copy-mode
# selection (mode-style), and the command prompt (message-command-style). Only
# bar/window/accent are required; mux-style derives the other three when a theme
# omits them.
#
# The palette itself lives as data in $MUX_DIR/themes/*.theme (single source),
# compiled into @theme-* options by mux-themes. run-shell loads it at server
# start and on every `mux reload`; mux also re-pushes on drift when a fragment
# changes, so an edit needs no manual step. mux-style reads @theme-* live, and
# themes/defaults carries the global default.
run-shell "mux themes load"

# Bootstrap the bar to the default palette so a session looks right the instant
# it is drawn, before run-shell finishes and before mux-style's create/attach
# hook re-derives it per pane. A static fallback mirroring purple; mux-style is
# authoritative within a tick.
set -g status-style                'bg=colour54 fg=colour189'
set -g window-status-current-style 'fg=colour232 bg=colour141 bold'
set -g message-style               'bg=colour54 fg=colour189'
set -g pane-active-border-style    'fg=colour141'
set -g pane-border-style           'fg=colour238'
set -g mode-style                  'fg=colour232 bg=colour141 bold'
set -g message-command-style       'bg=colour54 fg=colour189'

# --- the context reminder (the SIGNAL; the colour is not) ------------------
# When a pane's process is in a MARKED context (via the optional $MUX_DIR/
# context hook -- tackup uses it for its work/personal ZDR split), mux-style
# paints a loud banner in the status bar and a context prefix on the terminal
# title. It is TEXT, not colour, so the reminder does not depend on registering
# a hue -- the bar colour can be anything. The banner's own loud, theme-neutral
# style is a property of the context, so the context hook defines it (`banner
# <style>`), not this file.
#
# A REMINDER, NOT ENFORCEMENT: mux only REFLECTS the context in the UI. Whatever
# actually enforces it (for tackup, a kernel ACL on the work tree) lives in the
# integrator, not here. Never read the banner or the colour as permission.

# Terminal/window title: set-titles emits an OSC title to the outer terminal;
# @mux-prefix (set by mux-style, empty in an unmarked context) carries the
# context marker, #S:#W keeps the session:window visible, and [#{host_short}]
# tags the host the session lives on. host_short is the tmux SERVER's hostname,
# so a local session and an ssh'd one that share a name and layout get DISTINCT
# titles -- session-restore keys on the title and would otherwise snap the two
# windows onto each other.
#
# The gap before [host] is four U+2800 (Braille blank) chars, NOT spaces: kitty
# collapses runs of real whitespace (spaces AND non-breaking spaces) to a single
# space in the titlebar, so plain spaces cannot widen it. U+2800 renders blank
# but is not whitespace-class, so it survives. Do not replace these with spaces.
set -g set-titles on
set -g set-titles-string '#{@mux-prefix}#S:#W⠀⠀⠀⠀[#{host_short}]'

# status-left: mux-style's output FIRST -- the context banner (marked contexts
# only) then a per-host colour label -- then the session name. The host label
# disambiguates identically-named sessions across machines; mux-style emits it
# coloured per host (data in $MUX_DIR/hosts), so no host-specific config is
# needed. It also (re)applies the theme and title prefix as side effects every
# status-interval and on the hooks below. Length allows for banner + host + #S.
set -g status-left-length 100
set -g status-left '#(mux style #S #{pane_pid})#[bold]#S#[default] '
# A small orange marker on the left while a pane is zoomed (empty otherwise;
# commas inside the #{?...} escaped as #,). The LOUD mode banners -- a bright
# centred "PREFIX ENABLED" while the prefix is held, and the zoom EXIT hint --
# are drawn in the middle of the bar by mux-status-banner (run-shell below),
# which rebuilds status-format[0]. So prefix-held is unmissable and an
# accidental zoom is obviously recoverable.
set -ga status-left '#{?window_zoomed_flag,#[fg=16#,bg=214#] ⛶ #[default] ,}'
run-shell "mux status-banner"

# status-right: one token per session, in switch-client -n/-p order (prev left,
# next right), divider-separated and fixed-width so cycling never shifts them.
# #S (this bar's current session) is passed in so ONLY it is highlighted -- on
# its own themed window-status-current-style, matching the left active-window
# chip. Each token's emoji shows agent state (see agent-state-render): a caution
# triangle for needs-you, a brain for working, a check for finished, a black
# circle for no agent.
set -g status-interval 2
set -g status-right-length 160
# Trailing space: a one-column margin so the strip does not butt the right edge.
set -g status-right '#(mux agent-render #S #{client_name}) '

# tmux rescales panes proportionally on resize, so a mux bottom pane does not
# keep the height its layout asked for. Re-apply it whenever the geometry can
# have changed. Backgrounded so a hook never stalls the server.
#
# These two are the whole story: client-attached covers a client arriving at a
# size the session was not built for, client-resized covers the terminal being
# resized under a live client. There is no window-resized hook in tmux 3.6;
# set-hook takes the name without complaint and then never fires it.
# A hook command must produce NO stdout: tmux run-shell displays a command's
# output in a VIEW-MODE buffer over the active pane (even with -b), freezing it
# on a [0/0] snapshot until a key is pressed. mux-pin is silent already; the
# mux-style calls below use -q so their status-left banner never reaches stdout.
set-hook -g client-attached 'run-shell -b "mux pin"'
set-hook -g client-resized  'run-shell -b "mux pin"'

# status-left already re-runs mux-style every status-interval, which is what
# catches a context being entered in the pane you are already looking at. These
# two only make a new or newly attached session right immediately, rather than
# up to one interval late. -q: side effects only, no banner (see above).
set-hook -ag client-attached \
  'run-shell -b "mux style -q #S #{pane_pid}"'
set-hook -g  session-created \
  'run-shell -b "mux style -q #S #{pane_pid}"'
