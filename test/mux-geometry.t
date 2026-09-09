#!/bin/sh
# test/mux-geometry.t - a session must be BUILT at the size it will be shown at.
#
# tmux creates a detached session at `default-size`, which is 80x24. Every split
# is then sized against 24 rows -- a `bottom 5-10` pane takes 10 of them, 42% of
# the window -- and when the session is finally shown at a real terminal size
# tmux rescales every pane PROPORTIONALLY. A 10-row bottom becomes 22.
#
# `mux pin` exists to undo that, but it only ran from client-attached and
# client-resized. NEITHER fires when an already attached client switches to a
# session built detached: client-attached does not (the client was attached all
# along), client-resized does not (the CLIENT did not change size, the session
# did). That is `mux go NAME` from inside a session, and every session but the
# first after `mux resume` -- so those came up mis-proportioned and stayed that
# way until re-pinned by hand.
#
# Two fixes, and this pins the first: build at the right size, so there is no
# rescale to undo. (The second is the window-layout-changed hook in
# share/mux.tmux, which fires AFTER a rescale and catches a session shown at a
# size it was not built for.)
set -eu
_name=mux-geometry
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
# The size _session_geometry asks for when it is running inside tmux.
*window_width*)  printf '%s\n' "${FAKE_WH:-200 49}" ;;
*window_index*)  printf '0\n' ;;
*pane_id*)       printf '%%1\n' ;;
*'-gv status'*)  printf '%s\n' "${FAKE_STATUS:-on}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; export TMUXLOG
PATH=$T/bin:$PATH; export PATH

# go [ENV=VAL ...] : build in $T/proj and return the new-session command line.
# TMUX is scrubbed unconditionally and re-set only by a caller that wants the
# in-tmux path -- otherwise the suite's own environment decides which branch is
# under test, and running the tests inside tmux silently tests the wrong one.
go() {
	: >"$TMUXLOG"
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$@" "$HERE/bin/mux" go --no-agent \
		--no-attach ) >/dev/null 2>&1 || true
	grep 'new-session' "$TMUXLOG" | head -1
}
# Same, with no CONTROLLING TERMINAL, so /dev/tty cannot be opened. setsid is
# the only reliable way to get that: redirecting the three standard streams
# does not detach /dev/tty, so a suite run from a real terminal would otherwise
# find one and test the wrong branch.
go_headless() {
	: >"$TMUXLOG"
	( cd "$T/proj" && setsid env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" go --no-agent \
		--no-attach ) >/dev/null 2>&1 || true
	grep 'new-session' "$TMUXLOG" | head -1
}

# --- inside tmux: the current window's size, used EXACTLY -----------------
# tmux has already subtracted this client's status lines from window_height,
# so it needs no adjusting -- and guessing at it would reintroduce the bug at
# one row instead of twenty.
_o=$(go TMUX=/tmp/fake/global,1,0 FAKE_WH="200 49")
case $_o in
*"-x 200 -y 49"*) ;;
*) fail "in-tmux build did not carry the window size: [$_o]" ;;
esac

# A different client size must produce a different build size -- i.e. it is
# really being read, not hardcoded.
_o=$(go TMUX=/tmp/fake/global,1,0 FAKE_WH="100 30")
case $_o in
*"-x 100 -y 30"*) ;;
*) fail "in-tmux build ignored the client size: [$_o]" ;;
esac

# --- no terminal to ask: build with tmux's default, not a guess -----------
# A hook, a cron job, a headless script. Passing a made-up geometry here would
# be worse than passing none: mux would assert a size nothing asked for.
if command -v setsid >/dev/null 2>&1; then
	_o=$(go_headless)
	case $_o in
	*-x*|*-y*) fail "headless build invented a geometry: [$_o]" ;;
	esac
	case $_o in
	*new-session*) ;;
	*) fail "headless build created no session at all: [$_o]" ;;
	esac
fi

# --- the session is still built correctly in every other respect ----------
# The geometry flags must not have displaced the arguments after them.
_o=$(go TMUX=/tmp/fake/global,1,0 FAKE_WH="200 49")
case $_o in
*"-s mux-geometry-proj"*|*"-s proj"*) ;;
*) fail "the session name was lost: [$_o]" ;;
esac
case $_o in
*"-c $T/proj"*) ;;
*) fail "the root was lost: [$_o]" ;;
esac
case $_o in
*-d*) ;;
*) fail "the session is no longer built detached: [$_o]" ;;
esac

pass
