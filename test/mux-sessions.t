#!/bin/sh
# test/mux-sessions.t - the SESSION SET (libexec/mux-sessions.sh): which
# sessions a partition had, so a reboot is followed by `mux resume`.
#
# The two rules that matter and are easy to get wrong:
#   - it is ADDITIVE on create and SUBTRACTIVE on kill, never a snapshot of
#     what is live. A snapshot would be clobbered by the first `mux go` after
#     a reboot, destroying the record being rebuilt.
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
# Each partition resumes only its own; that is the whole point of keying on
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

# --- membership is NOT "has a root" -------------------------------------
# mux_sess_has answers whether a name is RECORDED. A record may legitimately
# carry an EMPTY root (tmux could not report session_path when it was added),
# so a non-empty-root test silently misses those entries -- and the caller
# that needs this is `mux kill`, deciding whether there is a record to forget.
# Getting it wrong there makes exactly those entries unforgettable.
mux_sess_has spacey $K || fail "has: a recorded name reads as absent"
mux_sess_has nosuch $K && fail "has: an unrecorded name reads as present"
mux_sess_add rootless "" $K
eq rootless-root "$(mux_sess_root rootless $K)" ""
mux_sess_has rootless $K || fail "has: an empty-root record reads as absent"
# ... and it stays idempotent through mux_sess_add, which shares the test.
mux_sess_add rootless "" $K
eq rootless-once "$(mux_sess_list $K | tr '\n' ' ')" "spacey rootless "
mux_sess_has spacey other && fail "has: not scoped to its partition"
mux_sess_has "" $K && fail "has: an empty name reads as present"

# --- IT LIVES IN $MUX_STATE, NOT $MUX_CACHE ---------------------------
# Nothing rebuilds this file: the set accumulates one `mux go` at a time. In
# ~/.cache it was one `rm -rf ~/.cache` away from gone, and the only moment you
# would notice is the `mux resume` after a reboot -- exactly when you cannot
# reconstruct it.
case "$(mux_sess_file probe)" in
"$MUX_STATE"/sessions.probe) ;;
*) fail "the set must live under \$MUX_STATE, got [$(mux_sess_file probe)].
~/.cache is by definition what anything may delete to reclaim space, and this
file is unreconstructible." ;;
esac

# --- AND AN OLD SET IN THE CACHE IS ADOPTED, NOT ORPHANED -------------
# The upgrade lands while sessions are already recorded, and the next thing to
# read them is likely a post-reboot resume. A set left in the old location would
# be a set lost at the one moment it mattered, so the move is automatic.
OLDC=$T/oldcache
mkdir -p "$OLDC"
printf 'legacy	%s/old
' "$T" >"$OLDC/sessions.adopt"
_sf=$(MUX_CACHE="$OLDC" mux_sess_file adopt)
[ -f "$_sf" ] || fail "the old set was not adopted into \$MUX_STATE"
eq adopt-content "$(cut -f1 "$_sf")" "legacy"
[ ! -e "$OLDC/sessions.adopt" ] \
	|| fail "the old file survived the move, so the next upgrade would see
two sets and the stale one could win"

# Idempotent, and it must never CLOBBER a set that already moved. If it did, an
# upgrade followed by real use would lose whatever was recorded after it.
printf 'stale	%s/stale
' "$T" >"$OLDC/sessions.adopt"
printf 'current	%s/cur
' "$T" >"$_sf"
_sf2=$(MUX_CACHE="$OLDC" mux_sess_file adopt)
eq adopt-no-clobber "$(cut -f1 "$_sf2")" "current"

pass
