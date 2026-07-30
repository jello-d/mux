#!/bin/sh
# mux-exclude.sh - shared paths for per-client session hiding (mux hide/show).
# A tmux client -- one attachment, keyed by its client_name (its tty) -- hides
# sessions from its own status strip and ( / ) cycling. client_name is unique
# per attachment, so it alone keys the set; no socket namespace is needed. The
# set lives under XDG_RUNTIME_DIR, so it clears on reboot. Sourced by ~/bin/mux,
# ~/lib/mux/mux-cycle, and ~/lib/mux/agent-state-render; defines functions only.

# mux_exclude_file <client-name> -> this client's hidden-sessions file path.
mux_exclude_file() {
        _rt=${XDG_RUNTIME_DIR:-/tmp/user-$(id -u)}
        _ck=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
        printf '%s/mux-exclude/%s' "$_rt" "$_ck"
}

# mux_excluded <client-name> -> space-separated hidden session names (or empty).
mux_excluded() {
        _f=$(mux_exclude_file "$1")
        [ -f "$_f" ] || return 0
        tr '\n' ' ' < "$_f"
}
