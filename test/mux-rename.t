#!/bin/sh
# test/mux-rename.t - `mux rename`, which moves three things that must agree:
# the live tmux session, the profile file, and the RECORDED SESSION SET.
#
# It had no test, and writing one found a bug. Renaming updated the session and
# the profile and left the recorded set alone, so:
#
#   mux rename alpha zulu   ->  live: zulu   recorded: alpha
#
# That is invisible until a REBOOT, and then `mux resume` rebuilds `alpha` (a
# session that no longer exists) and never restores `zulu`. A rename silently
# dropped the session from the very set that exists to bring it back. Same shape
# as the agent-state bugs: one store learns about a change, another does not.
#
# The other assertions here are about REFUSALS and about not clobbering, which
# is where a rename can destroy work rather than merely misplace it.
set -eu
_name=mux-rename
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/proj" "$T/cache"
LIVE=$T/live; export LIVE
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*has-session*)
	_n=${*##*=}
	grep -qxF "$_n" "$LIVE" 2>/dev/null && exit 0
	exit 1 ;;
*rename-session*)
	_o=$(printf '%s' "$*" | sed -n 's/.*-t =\([^ ]*\).*/\1/p')
	_n=${*##* }
	grep -vxF "$_o" "$LIVE" 2>/dev/null >"$LIVE.t" || :
	mv -f "$LIVE.t" "$LIVE"
	printf '%s\n' "$_n" >>"$LIVE" ;;
*display-message*session_name*) head -1 "$LIVE" ;;
*list-sessions*)
	[ -s "$LIVE" ] || exit 1
	cat "$LIVE" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/global.partition"

mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
		MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
# Same, but pretending to be INSIDE a session (the one-argument form).
mux_in() {
	( cd "$T/proj" && env -u MUX_SHARE TMUX=/tmp/fake/global,1,0 \
		PATH="$T/bin:$PATH" MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
SET=$T/state/sessions.global
live()     { sort "$LIVE" 2>/dev/null | tr '\n' ' '; }
recorded() { cut -f1 "$SET" 2>/dev/null | sort | tr '\n' ' '; }
root_of()  { awk -F'\t' -v n="$1" '$1==n{print $2}' "$SET" 2>/dev/null; }
reset() {
	printf 'alpha\n' >"$LIVE"
	printf 'alpha\t%s/proj\n' "$T" >"$SET"
	rm -f "$T/conf"/*.profile
}

# --- the recorded set must follow the rename ------------------------------
# The bug. Without this the set still names the OLD session, so resume rebuilds
# a session you renamed away and loses the one you kept.
reset
mux rename alpha zulu >/dev/null
[ "$(live)" = "zulu " ] || fail "the live session was not renamed: [$(live)]"
[ "$(recorded)" = "zulu " ] \
	|| fail "the recorded set did not follow the rename: [$(recorded)]"
# ... carrying the ROOT across, or resume has nowhere to rebuild it.
[ "$(root_of zulu)" = "$T/proj" ] \
	|| fail "the renamed entry lost its root: [$(root_of zulu)]"
# ... and `resume --list` is the surface that actually shows it.
_l=$(mux resume --list | tr '\n' ' ')
[ "$_l" = "zulu " ] || fail "resume --list still reports the old name: [$_l]"

# --- a rename must not CLOBBER an existing profile ------------------------
# The work-losing case. If NEW already has a profile, the old one must not
# overwrite it; the session rename still happens.
reset
printf 'old settings\n' >"$T/conf/alpha.profile"
printf 'KEEP ME\n' >"$T/conf/zulu.profile"
mux rename alpha zulu >/dev/null
grep -qx 'KEEP ME' "$T/conf/zulu.profile" \
	|| fail "rename clobbered an existing profile"
[ -f "$T/conf/alpha.profile" ] \
	|| fail "the old profile was removed even though it was not moved"

# --- ... but it DOES follow when the target is free ----------------------
reset
printf 'old settings\n' >"$T/conf/alpha.profile"
_o=$(mux rename alpha zulu)
[ -f "$T/conf/zulu.profile" ] || fail "the profile did not follow the rename"
[ ! -f "$T/conf/alpha.profile" ] || fail "the old profile was left behind"
grep -qx 'old settings' "$T/conf/zulu.profile" \
	|| fail "the profile contents changed in the move"
case $_o in
*"renamed profile"*) ;;
*) fail "the profile move was silent" ;;
esac

# --- tmux target metacharacters are folded -------------------------------
# `:` and `.` are tmux's window/pane separators in a target, so a session named
# with them cannot be addressed as `=NAME` afterwards.
reset
mux rename alpha 'a:b.c' >/dev/null
[ "$(live)" = "a-b-c " ] || fail "':' and '.' were not folded: [$(live)]"
[ "$(recorded)" = "a-b-c " ] \
	|| fail "the recorded set kept the unfolded name: [$(recorded)]"

# --- renaming an unknown session is a loud refusal ----------------------
reset
_rc=0; _o=$(mux rename nosuch zulu) || _rc=$?
[ "$_rc" -ne 0 ] || fail "renaming an unknown session exited 0"
case $_o in *"no such session"*) ;; *) fail "unhelpful refusal: $_o" ;; esac
[ "$(live)" = "alpha " ] || fail "a failed rename still changed the live set"
[ "$(recorded)" = "alpha " ] \
	|| fail "a failed rename still changed the recorded set"

# --- exact match: renaming `api` must not catch `api-old` ---------------
printf 'api\napi-old\n' >"$LIVE"
printf 'api\t%s/proj\napi-old\t%s/proj\n' "$T" "$T" >"$SET"
mux rename api renamed >/dev/null
[ "$(live)" = "api-old renamed " ] \
	|| fail "rename hit the wrong session: [$(live)]"
[ "$(recorded)" = "api-old renamed " ] \
	|| fail "the recorded set renamed the wrong entry: [$(recorded)]"

# --- the one-argument form needs a session to be in ---------------------
# Outside tmux there is no "current session" to rename, and guessing would be
# worse than refusing.
reset
_rc=0; _o=$(mux rename zulu) || _rc=$?
[ "$_rc" -ne 0 ] || fail "a bare rename outside tmux exited 0"
case $_o in
*"needs a session"*) ;;
*) fail "the refusal did not explain the two forms: $_o" ;;
esac
[ "$(live)" = "alpha " ] || fail "a refused rename still renamed something"

# --- ... and works inside one, renaming the session you are in ----------
reset
mux_in rename zulu >/dev/null
[ "$(live)" = "zulu " ] || fail "the in-session form did not rename: [$(live)]"
[ "$(recorded)" = "zulu " ] \
	|| fail "the in-session form skipped the recorded set: [$(recorded)]"

pass
