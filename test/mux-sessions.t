#!/bin/sh
# test/mux-sessions.t - the SESSION SET (libexec/mux-sessions.sh): which
# sessions a partition had, so a reboot is followed by `mux restore`.
#
# The two rules that matter and are easy to get wrong:
#   - it is ADDITIVE on create and SUBTRACTIVE on kill, never a snapshot of
#     what is live. A snapshot would be clobbered by the first `mux go` after
#     a reboot, destroying the record being restored.
#   - each entry carries the ROOT, not just the name. The common session is a
#     bare `mux go` in a directory, which has no profile and no map entry, so
#     the name alone cannot rebuild it.
#
# Pure file logic against a scratch cache; no tmux.
set -eu
_name=mux-sessions
. "$(dirname "$0")/lib.sh"
. "$HERE/libexec/mux-sessions.sh"

MUX_CACHE=$T/cache
export MUX_CACHE
K=probe

eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- empty --------------------------------------------------------------
eq empty-list "$(mux_sess_list $K)" ""
eq empty-root "$(mux_sess_root alpha $K)" ""
mux_sess_drop alpha $K || fail "dropping from an absent set should be a no-op"

# --- add, in insertion order --------------------------------------------
mux_sess_add alpha "$T/a" $K
mux_sess_add bravo "$T/b" $K
mux_sess_add charlie "$T/c" $K
eq order "$(mux_sess_list $K | tr '\n' ' ')" "alpha bravo charlie "
eq root-a "$(mux_sess_root alpha $K)" "$T/a"
eq root-c "$(mux_sess_root charlie $K)" "$T/c"
eq root-absent "$(mux_sess_root nosuch $K)" ""

# Idempotent: re-adding must not duplicate, so recording on every attach (not
# just on build) is safe and heals a set made before the feature existed.
mux_sess_add alpha "$T/a" $K
eq idempotent "$(mux_sess_list $K | tr '\n' ' ')" "alpha bravo charlie "

# --- drop ---------------------------------------------------------------
mux_sess_drop bravo $K
eq dropped "$(mux_sess_list $K | tr '\n' ' ')" "alpha charlie "
eq dropped-root "$(mux_sess_root bravo $K)" ""
# The others keep their roots -- a drop rewrites the file, so this is the
# check that it rewrites it correctly.
eq drop-keeps "$(mux_sess_root charlie $K)" "$T/c"
mux_sess_drop nosuch $K
eq drop-absent "$(mux_sess_list $K | tr '\n' ' ')" "alpha charlie "

# --- per partition ------------------------------------------------------
# Each partition restores only its own; that is the whole point of keying on
# it, so a work set must be invisible from a personal one.
mux_sess_add delta "$T/d" other
eq other-part "$(mux_sess_list other | tr '\n' ' ')" "delta "
eq this-part "$(mux_sess_list $K | tr '\n' ' ')" "alpha charlie "

# --- clear --------------------------------------------------------------
mux_sess_clear $K
eq cleared "$(mux_sess_list $K)" ""
eq clear-is-scoped "$(mux_sess_list other | tr '\n' ' ')" "delta "

# --- a root containing a space survives ---------------------------------
# The file is TAB-separated precisely so this works; a space-separated one
# would truncate the root at the first space.
mux_sess_add spacey "$T/has space" $K
eq spaced-root "$(mux_sess_root spacey $K)" "$T/has space"
eq spaced-name "$(mux_sess_list $K | tr '\n' ' ')" "spacey "

pass
