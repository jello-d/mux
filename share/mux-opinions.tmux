# mux-opinions.tmux -- mux's OPTIONAL ergonomic defaults, distinct from the
# required feature wiring in mux.tmux. Pure tmux preference (mouse, scroll
# routing, navigation) that suits an agent-heavy, many-session workflow but is
# not needed for mux's features to work. `source-file` it for a good out-of-the-
# box feel, or skip it and bring your own. A binding set after this file wins.

# Mouse on: tmux owns the mouse, so a drag-select is confined to the pane under
# the cursor (into copy-mode) instead of the terminal selecting a band across
# the whole window. This works over ssh -- mouse events are escape sequences
# travelling in the same stream as keystrokes, interpreted by the (possibly
# remote) tmux. Hold Shift while dragging to bypass tmux for a raw selection.
# It also enables the status-bar chip click bound in mux.tmux.
set -g mouse on
# ...but NOT mouse pane-resize: dragging a pane border fires MouseDrag1Border ->
# resize-pane, so a copy/highlight drag that starts on or crosses a border
# yanks the divider (a false resize). Unbind just that one root-table binding;
# click-select, drag-select into copy-mode, and scroll are untouched.
unbind -n MouseDrag1Border
# set-clipboard on: a copy-mode selection (and any paste-buffer set) also sets
# the terminal clipboard via an OSC 52 escape, so a copy made on a session you
# attached to remotely reaches your LOCAL system clipboard.
set -g set-clipboard on

# Scroll keys behave per pane. PageUp pages an alt-screen app (a coding agent,
# vim) through, and drops a shell into tmux copy-mode over its scrollback. The
# wheel routes three ways: an app that grabs the mouse gets it raw and scrolls
# itself; an alt-screen app that does not take the mouse gets arrow keys, so the
# wheel still scrolls it; a shell drops into copy-mode.
bind -n PageUp if -F '#{alternate_on}' 'send PageUp' 'copy-mode -eu'
bind -n WheelUpPane if -F '#{mouse_any_flag}' 'send -M' \
  "if -F '#{alternate_on}' 'send -N 3 Up' 'copy-mode -e'"
bind -n WheelDownPane if -F '#{mouse_any_flag}' 'send -M' \
  "if -F '#{alternate_on}' 'send -N 3 Down' 'send -M'"

# Space = the explorer. choose-tree spans sessions -> windows -> panes in one
# picker, so it jumps anywhere. This also overrides the next-layout default,
# which silently re-tiled the session. prefix+s / prefix+w stay as quick
# session/window pickers.
bind Space choose-tree -Z

# Tab = cycle this session's tabs (windows) -- the linear "next thing in this
# context". Repeatable so you can tap Tab, Tab, Tab; n / p keep working as
# aliases.
bind -r Tab  next-window
bind -r BTab previous-window
