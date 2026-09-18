#!/bin/sh
# mux-exclude.sh - shared paths for per-client session hiding (mux hide/show).
# A tmux client -- one attachment, keyed by its client_name (its tty) -- hides
# sessions from its own status strip and ( / ) cycling. client_name is unique
# per attachment, so it alone keys the set; no socket namespace is needed. The
# set lives under XDG_RUNTIME_DIR, so it clears on reboot. Sourced by the mux
# entry point and by mux-cycle / agent-state-render; defines functions only.

# mux_exclude_file <client-name> -> this client's hidden-sessions file path.
mux_exclude_file() {
        _rt=${XDG_RUNTIME_DIR:-/tmp/user-$(id -u)}
        _ck=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
        printf '%s/mux-exclude/%s' "$_rt" "$_ck"
}

# The only delimiter safe for a set of session names. A name MAY contain a
# space -- tmux accepts `my project` and reports it intact -- so a space-joined
# set cannot be searched for one member without finding its words. A newline
# cannot appear: tmux's own -F output is line oriented and escapes one (a name
# built with a literal newline comes back as `a\nb`), so every name mux ever
# sees is newline free. Verified against real tmux, not assumed.
MUX_EXCL_NL='
'

# mux_excluded <client-name> -> the hidden set, ONE NAME PER LINE (or empty).
mux_excluded() {
        _f=$(mux_exclude_file "$1")
        [ -f "$_f" ] || return 0
        cat "$_f"
}

# mux_excluded_has <set> <name> -> is NAME hidden? Whole-line exact match.
#
# The test this replaces joined the set with spaces and asked
# `case " $set " in *" $name "*)`, which makes every WORD of a hidden name a
# member: hiding `my project` also hid unrelated sessions called `my` and
# `project`. Measured, with exactly one session hidden.
#
# Takes the SET rather than the client so a caller reads the file once and then
# tests every session against it -- the status strip does this on every redraw.
mux_excluded_has() {
        case "$MUX_EXCL_NL$1$MUX_EXCL_NL" in
        *"$MUX_EXCL_NL$2$MUX_EXCL_NL"*) return 0 ;;
        esac
        return 1
}
