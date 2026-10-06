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
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/proj" "$T/cache"
LIVE=$T/live; export LIVE
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*has-session*)
  _n=$*; _n=${_n##*=}
  grep -qxF "$_n" "$LIVE" 2>/dev/null && exit 0
  exit 1 ;;
*rename-session*)
  _o=$(printf '%s' "$*" | sed -n 's/.*-t =\([^ ]*\).*/\1/p')
  _n=$*; _n=${_n##* }
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
_o=$(mux rename alpha zulu) || fail "rename failed: $_o"
[ "$(live)" = "zulu " ] || fail "the live session was not renamed: [$(live)]"
[ "$(recorded)" = "zulu " ] \
  || fail "the recorded set did not follow the rename: [$(recorded)]"
# ... carrying the ROOT across, or resume has nowhere to rebuild it.
[ "$(root_of zulu)" = "$T/proj" ] \
  || fail "the renamed entry lost its root: [$(root_of zulu)]"
# ... and `resume --list` is the surface that actually shows it.
_l=$(mux resume --list | tr '\n' ' ') \
  || fail "resume --list exited non-zero after a rename: [$_l]"
[ "$_l" = "zulu " ] || fail "resume --list still reports the old name: [$_l]"

# --- a rename must not CLOBBER an existing profile ------------------------
# The work-losing case. If NEW already has a profile, the old one must not
# overwrite it; the session rename still happens.
reset
printf 'old settings\n' >"$T/conf/alpha.profile"
printf 'KEEP ME\n' >"$T/conf/zulu.profile"
_o=$(mux rename alpha zulu) || fail "rename failed: $_o"
grep -qx 'KEEP ME' "$T/conf/zulu.profile" \
  || fail "rename clobbered an existing profile"
[ -f "$T/conf/alpha.profile" ] \
  || fail "the old profile was removed even though it was not moved"

# --- ... but it DOES follow when the target is free ----------------------
reset
printf 'old settings\n' >"$T/conf/alpha.profile"
_o=$(mux rename alpha zulu) || fail "rename failed: $_o"
[ -f "$T/conf/zulu.profile" ] || fail "the profile did not follow the rename"
[ ! -f "$T/conf/alpha.profile" ] || fail "the old profile was left behind"
grep -qx 'old settings' "$T/conf/zulu.profile" \
  || fail "the profile contents changed in the move"
case $_o in
  *"renamed profile"*) ;;
  *) fail "the profile move was silent" ;;
esac

# --- A DOT IS FOLDED, A COLON IS REFUSED, and they are two rules ---------
# They used to be one (`tr ':.' '--'`), and separating them is the point.
#
# THE DOT IS A COMPATIBILITY RULE WITH A VERSION ATTACHED: tmux up to 3.6
# rewrites it in a session name, so mux has to agree with what tmux will
# actually store or `has-session -t =NAME` stops matching the name mux
# recorded. mux's own grammar stopped using a dot, so nothing here is
# reserved: it is folded because of the tool, not because of mux.
reset
_o=$(mux rename alpha 'a.c') \
  || fail "renaming to a name with a dot failed: $_o"
[ "$(live)" = "a-c " ] || fail "'.' was not folded: [$(live)]"
[ "$(recorded)" = "a-c " ] \
  || fail "the recorded set kept the unfolded name: [$(recorded)]"

# THE COLON IS RESERVED BY MUX, and a name the user TYPED is refused rather
# than quietly rewritten: handing back a different session from the one asked
# for is plausible, wrong and silent, which is this package's signature
# failure. tmux 3.7 stopped rewriting it (measured: 3.7c sanitises session
# names not at all), so the guarantee the address grammar rests on is mux's
# now, and a colon is tmux's own window separator anyway, so such a session
# could not be reached by a plain `tmux -t` either.
reset
_rc=0; _o=$(mux rename alpha 'a:b') || _rc=$?
[ "$_rc" = 2 ] || fail "a typed colon must be refused with 2, got $_rc: $_o"
case $_o in
  *'cannot contain a colon'*) ;;
  *) fail "the refusal did not say what the rule is: $_o" ;;
esac
case $_o in
  *'mux rename alpha a-b'*) ;;
  *) fail "the refusal did not PRESCRIBE the name that would work, so someone
hits a rule with no way out of it: $_o" ;;
esac
[ "$(live)" = "alpha " ] \
  || fail "a REFUSED rename still changed the live set: [$(live)]"

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
_o=$(mux rename api renamed) \
  || fail "renaming a profiled session failed: $_o"
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
