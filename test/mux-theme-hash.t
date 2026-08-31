#!/bin/sh
# test/mux-theme-hash.t - a session with no `theme` of its own gets one derived
# from its NAME, so a project wears a stable colour with nothing configured.
# Pinning a colour was the single most common reason to write a profile at all.
#
# The contract is STABILITY, not uniqueness: the same name must always land on
# the same theme (you learn "api is the green one"), and two names colliding is
# accepted and fixed with `mux theme`. Priority: an explicit theme in the
# profile wins, then the context's, then this, then the global default.
#
# tmux is stubbed, so no server is started.
set -eu
_name=mux-theme-hash
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/themes" "$T/proj"
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

# themeof NAME [PROFILE] -> the theme mux set on the session, or empty.
themeof() {
	: >"$TMUXLOG"
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" go "$@" ) >/dev/null 2>&1 \
		|| fail "mux go $* exited $?"
	awk '/@mux-theme /{print $NF; exit}' "$TMUXLOG"
}

# --- derived, and STABLE ----------------------------------------------------
_a=$(themeof alpha)
[ -n "$_a" ] || fail "no theme derived for an unconfigured session"
_a2=$(themeof alpha)
[ "$_a" = "$_a2" ] || fail "unstable: alpha got [$_a] then [$_a2]"

# A different name generally lands elsewhere. Not guaranteed for any given
# pair (collisions are accepted), so assert over a spread instead: several
# distinct names must not all collapse onto one theme.
_seen=$(for _n in alpha bravo charlie delta echo foxtrot; do
	themeof "$_n"
done | sort -u | grep -c .)
[ "$_seen" -ge 3 ] \
	|| fail "6 names produced only $_seen distinct themes; hash is degenerate"

# --- the derived theme must be a REAL one -----------------------------------
[ -n "$(MUX_DIR=$T/conf; . "$HERE/libexec/mux-data.sh"
	MUX_SHARE=$HERE/share mux_data_find themes "$_a" .theme)" ] \
	|| fail "derived theme [$_a] is not a themes/*.theme that exists"

# --- an explicit theme in the profile wins ----------------------------------
printf 'theme   red\n' >"$T/conf/pinned.profile"
_p=$(themeof pinned)
[ "$_p" = red ] || fail "explicit theme lost: got [$_p], want red"

# --- `derive off` falls back to the global default --------------------------
# mux sets no @mux-theme at all then, leaving mux-style to use @theme-default.
printf 'default purple\nderive  off\n' >"$T/conf/themes/defaults"
_o=$(themeof offcase)
[ -z "$_o" ] || fail "derive off should set no @mux-theme, got [$_o]"
# ... and turning it back on resumes the SAME colour the name had before.
printf 'default purple\nderive  hash\n' >"$T/conf/themes/defaults"
_a3=$(themeof alpha)
[ "$_a3" = "$_a" ] || fail "derive re-enabled: got [$_a3], want [$_a]"

pass
