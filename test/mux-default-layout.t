#!/bin/sh
# test/mux-default-layout.t - a FRESH install must be able to run `mux go`.
# With an empty $MUX_DIR and no per-project layout, `mux go NAME` falls back to
# `default`; with no shipped share/default.layout that died on
# "mux: no layout: default", which is the verb every quickstart opens with.
#
# tmux is stubbed in $T/bin and logs the session-building calls, so the run goes
# all the way through the build pass without starting a server or touching any
# real session. $MUX_DIR is a scratch dir (the empty-overlay case) and the cwd
# is a scratch dir, so no layout of the developer's can satisfy the lookup.
set -eu
_name=mux-default-layout
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/emptyconf" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
# No server anywhere: `mux themes sync` skips every heal and `has-session`
# reports the session missing, so mux takes the BUILD path.
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

TMUXLOG=$T/log; : >"$TMUXLOG"
export TMUXLOG
PATH=$T/bin:$PATH
export PATH

# -u MUX_SHARE so bin/mux self-locates THIS checkout's share/, not an installed
# one; -u TMUX so the run reads as a plain shell, not a live client.
( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/emptyconf" \
	MUX_CACHE="$T/cache" "$HERE/bin/mux" go zz-scratch ) \
	|| fail "mux go on a fresh install exited $?"

# The shape actually got built: a session named zz-scratch, opened on the
# window the default layout declares, and a full-width bottom pane.
grep -q 'new-session -d -s zz-scratch -n code' "$TMUXLOG" \
	|| fail "no new-session for the default layout (see $TMUXLOG)"
grep -q 'split-window -v -f' "$TMUXLOG" \
	|| fail "the default layout built no bottom pane"
grep -q 'attach-session -t =zz-scratch' "$TMUXLOG" \
	|| fail "mux did not attach the session it built"

# An explicit LAYOUT that does not exist must still fail loud -- the fallback
# is for the NO-layout case, it must not paper over a typo.
if ( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/emptyconf" \
	MUX_CACHE="$T/cache" "$HERE/bin/mux" go zz-scratch nosuchlayout \
	>/dev/null 2>&1 ); then
	fail "an unknown explicit LAYOUT should fail, not fall back to default"
fi

pass
