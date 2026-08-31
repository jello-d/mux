#!/bin/sh
# test/mux-profile.t - the profile/layout split. A PROFILE carries identity and
# appearance (root, theme, agent, notify) and NAMES an arrangement; a LAYOUT
# carries the arrangement (window/pane/bottom) and nothing else. A directive in
# the wrong file must fail loud rather than half-work, and `include` (which one
# recursive splice replaced) must point at the migrator.
#
# tmux is stubbed in $T/bin and logs the build calls, so no server is started
# and no real session is touched.
set -eu
_name=mux-profile
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/layouts" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; export TMUXLOG
PATH=$T/bin:$PATH; export PATH

# go NAME... -> run `mux go`, echoing combined output; log reset each time.
go() {
	: >"$TMUXLOG"
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" go "$@" ) 2>&1
}
has() {  # LABEL PATTERN
	grep -q "$2" "$TMUXLOG" || fail "$1: no [$2] in the tmux log"
}
fails() { # LABEL WANT ARGS...
	_l=$1 _w=$2; shift 2
	_o=$(go "$@") && fail "$_l: expected a non-zero exit"
	case $_o in *"$_w"*) ;; *) fail "$_l: want [$_w], got [$_o]" ;; esac
}

# --- a profile may be nothing but a theme ----------------------------------
# The arrangement then comes from the shipped layouts/default, which is the
# whole point: a profile records a DEVIATION, not a whole session.
printf 'theme   cyan\n' >"$T/conf/themeonly.profile"
go themeonly >/dev/null
has themeonly-builds 'new-session -d -s themeonly'
has themeonly-bottom 'split-window -v -f'
has themeonly-theme  '@mux-theme cyan'

# --- a profile names a layout ----------------------------------------------
printf 'window solo\npane    agent\n' >"$T/conf/layouts/solo.layout"
printf 'layout  solo\nroot    %s\n' "$T/proj" >"$T/conf/named.profile"
go named >/dev/null
has named-window 'new-session -d -s named -n solo'
grep -q 'split-window -v -f' "$TMUXLOG" \
	&& fail "named: the solo layout has no bottom, one was built anyway"

# --- the split is enforced BOTH ways ---------------------------------------
printf 'window nope\npane\n' >"$T/conf/inprofile.profile"
fails arrangement-in-profile "belongs in a layout, not a profile" inprofile

printf 'theme red\nwindow w\npane\n' >"$T/conf/layouts/bad.layout"
printf 'layout  bad\n' >"$T/conf/inlayout.profile"
fails identity-in-layout "belongs in a profile, not a layout" inlayout

# --- retired syntax points at the fix, it does not silently ignore ---------
printf 'include shapes/code\n' >"$T/conf/legacy.profile"
fails include-retired "mux-migrate-profiles" legacy

# --- a named layout that does not exist fails loud -------------------------
printf 'layout  ghost\n' >"$T/conf/ghost.profile"
fails missing-layout "no layout: ghost" ghost

# --- a pre-rename .profile-less <name>.layout is still READ, with a warning -
# Transitional: deploying a new mux and converting a config are separate acts.
printf 'theme   green\n' >"$T/conf/old.layout"
_o=$(go old) || fail "a pre-rename .layout should still build"
case $_o in
*"pre-rename"*) ;;
*) fail "a pre-rename .layout must warn, got [$_o]" ;;
esac
has legacy-builds '@mux-theme green'

pass
