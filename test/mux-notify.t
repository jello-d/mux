#!/bin/sh
# test/mux-notify.t - mux raises a desktop notification when an agent stops
# needing the CPU and starts needing YOU, and clears it once that state passes.
#
# Raising was always portable (notify-send is libnotify). CLEARING was hardcoded
# to `makoctl dismiss`, so the "needs you" banner only ever cleaned itself up
# under mako on Wayland; everywhere else the call was a silent no-op and the
# banner sat there until swatted by hand. Closing by id is in the freedesktop
# spec, as org.freedesktop.Notifications.CloseNotification, so the portable
# close is a D-Bus call and the only variable is which D-Bus CLI exists.
#
# Every backend is stubbed here and PATH is reduced to the stub dir, so this
# proves the SELECTION and the command shape without a session bus, a daemon,
# or a notification on anyone's screen.
set -eu
_name=mux-notify
. "$(dirname "$0")/lib.sh"
. "$HERE/libexec/mux-notify.sh"

mkdir -p "$T/bin"
LOG=$T/log
export LOG

# Stub every backend to log "<name> <args>". notify-send also prints an id, as
# `-p` makes the real one do.
for _c in gdbus busctl dbus-send makoctl; do
	cat >"$T/bin/$_c" <<EOF
#!/bin/sh
printf '%s %s\n' "$_c" "\$*" >>"\$LOG"
exit 0
EOF
	chmod +x "$T/bin/$_c"
done
cat >"$T/bin/notify-send" <<'EOF'
#!/bin/sh
printf 'notify-send %s\n' "$*" >>"$LOG"
printf '4242\n'
EOF
chmod +x "$T/bin/notify-send"

# The MUX_NOTIFY_* overrides, as a platform that is not freedesktop would
# supply them: real scripts, addressed absolutely, so they run whatever PATH
# the case under test has left.
cat >"$T/mysend" <<'EOF'
#!/bin/sh
printf 'mysend %s|%s|%s\n' "$1" "$2" "$3" >>"$LOG"
printf 'tok-9\n'
EOF
cat >"$T/myclose" <<'EOF'
#!/bin/sh
printf 'myclose %s\n' "$1" >>"$LOG"
EOF
chmod +x "$T/mysend" "$T/myclose"

_saved=$PATH

# only BACKENDS... : run with PATH holding ONLY the named stubs, so `command
# -v` sees exactly the backends under test. The real PATH is restored FIRST --
# a reduced PATH has no rm/mkdir/cp either, and the second call would otherwise
# have no tools to rebuild the dir with. MUX_NOTIFY_CLOSER is cleared because
# the lib caches its probe there.
only() {
	PATH=$_saved
	rm -rf "$T/only"; mkdir -p "$T/only"
	for _b; do cp "$T/bin/$_b" "$T/only/$_b"; done
	: >"$LOG"
	# Deliberately REPLACING PATH: the point is a host with no backend.
	# shellcheck disable=SC2123
	PATH=$T/only MUX_NOTIFY_CLOSER=
}
# Pure shell, for the same reason: `cat` is not on the reduced PATH.
logged() {
	_l=
	if [ -f "$LOG" ]; then
		while IFS= read -r _ln; do _l=$_l$_ln'
'; done <"$LOG"
	fi
	printf '%s' "$_l"
}
has() {
	case "$(logged)" in
	*"$1"*) ;;
	*) fail "$2: want [$1] in log, got [$(logged)]" ;;
	esac
}

# --- close: the backend preference order -----------------------------------
# gdbus first, then busctl, then dbus-send, and makoctl LAST -- it is kept only
# so a mako box with no D-Bus CLI keeps the behaviour it had.
only gdbus busctl dbus-send makoctl
mux_notify_close 7
has 'gdbus call' "all four present"
has 'CloseNotification' "all four present: not the spec method"
case "$(logged)" in *makoctl*) fail "makoctl won over gdbus" ;; esac

only busctl dbus-send makoctl
mux_notify_close 7
has 'busctl --user call' "no gdbus"
has 'CloseNotification u 7' "no gdbus: wrong busctl signature"

only dbus-send makoctl
mux_notify_close 7
has 'dbus-send --session' "only dbus-send and makoctl"
has 'uint32:7' "dbus-send needs a typed uint32 argument"

only makoctl
mux_notify_close 7
has 'makoctl dismiss -n 7' "makoctl is the last resort"

# --- close: the quiet paths ------------------------------------------------
# An empty id is the COMMON case (most state files carry no notification), so
# it must not shell out at all.
only gdbus
mux_notify_close ""
[ -z "$(logged)" ] || fail "an empty id still called a backend: $(logged)"

# No backend at all is a machine where mux clears nothing. That is not an
# error: this runs inside a Claude Code hook, where non-zero means failed hook.
only
mux_notify_close 7 || fail "close must not fail with no backend"
[ -z "$(logged)" ] || fail "no backend, yet something ran: $(logged)"

# --- send: normal urgency, never critical ----------------------------------
# critical means "never expire" to mako and dunst alike, which is what made the
# old banner outlive the prompt it announced.
only notify-send
_id=$(mux_notify_send normal "Claude needs you: alpha" "permission or input")
[ "$_id" = 4242 ] || fail "send did not return the id: [$_id]"
has '-u normal' "send: urgency"
has '-p' "send: must ask for the id it returns"
has '-a mux' "send: app name, so a daemon rule can match mux alone"
case "$(logged)" in *critical*) fail "send used critical urgency" ;; esac

# No notify-send is silent and successful, same reasoning as close.
only
_id=$(mux_notify_send normal sum body) || fail "send must not fail bare"
[ -z "$_id" ] || fail "send invented an id with no backend: [$_id]"

# --- the escape hatch for a platform that is not freedesktop ---------------
# Both overrides bypass detection entirely, so a macOS or relay backend needs
# no change here. An id is opaque: whatever send prints, close gets back.
only gdbus notify-send
MUX_NOTIFY_SEND=$T/mysend
export MUX_NOTIFY_SEND
_id=$(mux_notify_send normal "sum" "body")
[ "$_id" = tok-9 ] || fail "override send: id not passed through: [$_id]"
has 'mysend normal|sum|body' "override send: args"
case "$(logged)" in *notify-send*) fail "override did not bypass notify-send"
esac
unset MUX_NOTIFY_SEND

: >"$LOG"
MUX_NOTIFY_CLOSE=$T/myclose
export MUX_NOTIFY_CLOSE
mux_notify_close tok-9
has 'myclose tok-9' "override close: the opaque id comes back"
case "$(logged)" in *gdbus*) fail "override did not bypass gdbus" ;; esac
unset MUX_NOTIFY_CLOSE

PATH=$_saved

# --- the POLICY, at the one place that sets it -----------------------------
# Everything above tests the mechanism. The urgency mux actually PASSES is
# agent-state-emit's decision, so it is asserted against the real script: a lib
# that merely accepts `normal` proves nothing if the caller still says
# `critical`. Driven end to end with tmux stubbed, no server and no daemon.
mkdir -p "$T/emitbin" "$T/run"
cat >"$T/emitbin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*session_name*)       printf 'alpha 0\n' ;;
*mux-notify-always*)  printf '\n' ;;
*pane_active*)        printf '0\n' ;;   # not on screen -> do notify
esac
exit 0
EOF
cp "$T/bin/notify-send" "$T/emitbin/notify-send"
cp "$T/bin/gdbus" "$T/emitbin/gdbus"
chmod +x "$T/emitbin/tmux"

_sf=$T/run/agent-state/global/5
emit() {
	env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%5 \
		PATH="$T/emitbin:$_saved" LOG="$LOG" \
		"$HERE/libexec/agent-state-emit" "$1"
}
# Record: state window pane epoch notif SESSION. The notif id is field 5 --
# the session moved to the END so a name containing a space survives, and
# notif is `-` rather than empty so an absent one cannot shift the fields.
notif_of() {
	read -r _a _b _c _d _e _f <"$_sf" || true
	case ${_e:-} in -|'') printf '' ;; *) printf '%s' "$_e" ;; esac
}

# Starting work notifies nobody -- that transition is YOU, not the agent.
: >"$LOG"
emit working || fail "emit working failed"
case "$(logged)" in *notify-send*) fail "starting work raised a banner" ;; esac

# working -> blocked is the agent handing back. Normal urgency, and the id it
# returns is retained so the transition away can clear it.
: >"$LOG"
emit blocked || fail "emit blocked failed"
has 'notify-send' "blocked: no notification raised at all"
has '-u normal' "blocked: urgency is not normal"
case "$(logged)" in
*critical*) fail "blocked still raises a CRITICAL (never-expiring) banner" ;;
esac
[ "$(notif_of)" = 4242 ] || fail "the id was not kept: [$(notif_of)]"

# Leaving that state clears the banner it raised, through the portable close.
: >"$LOG"
emit working || fail "emit working (clearing) failed"
has 'CloseNotification' "leaving blocked did not close the notification"
has '4242' "closed some other id"
[ -z "$(notif_of)" ] || fail "a cleared id is still on file: [$(notif_of)]"

# The record is written ATOMICALLY: a reader never sees a torn or empty line.
# Several hooks fire close together -- a tool finishing as a turn ends -- and a
# plain redirect truncates before it writes, so a render landing in that gap
# reads a session as having no agent at all.
: >"$LOG"
emit working || fail "emit working (atomicity) failed"
[ "$(wc -l <"$_sf")" -eq 1 ] || fail "the record is not exactly one line"
# No temp file may survive the write.
_left=$(ls "$T/run/agent-state/global")
case $_left in
*.[0-9]*) fail "a temp file was left behind: $_left" ;;
esac

# The opt-in breadcrumb records the transition AND what it came from, which is
# what makes a stuck state traceable to the hook that last wrote it.
_bc=$T/emit.log
: >"$_bc"
env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%5 \
        PATH="$T/emitbin:$_saved" LOG="$LOG" MUX_EMIT_LOG="$_bc" \
        "$HERE/libexec/agent-state-emit" idle >/dev/null 2>&1 || true
case "$(cat "$_bc")" in
*idle*was=working*) ;;
*) fail "the breadcrumb did not record the transition: [$(cat "$_bc")]" ;;
esac
# Off by default: no log path, no file, no cost.
_bc2=$T/never.log
emit working >/dev/null 2>&1 || true
[ ! -f "$_bc2" ] || fail "a breadcrumb was written without MUX_EMIT_LOG"

# --- a notification id must AGE OUT, not be acted on years later ----------
# FOUND LIVE on `charon`: an idle record holding notification id 522 for 32
# HOURS. The carry is per-STATE, not per-notification, so a session that
# finishes and is never touched again keeps its id indefinitely, and the next
# transition would dutifully "close" it.
#
# By then the id names somebody else's banner. A freedesktop id is a small
# integer the daemon assigns sequentially and REUSES after it restarts, so
# closing a day-old id dismisses an unrelated notification.
#
# Dropping it loses nothing only because 0.14 moved to `normal` urgency, which
# expires on its own. Under `critical` this would be a leak instead.
mkdir -p "$T/ttlbin"
cat >"$T/ttlbin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*window_index*session_name*) printf '0 charon
' ;;
*mux-notify-always*)         printf '
' ;;
*pane_active*)               printf '1
' ;;
esac
exit 0
EOF
chmod +x "$T/ttlbin/tmux"
CLOSELOG=$T/closelog; export CLOSELOG
cat >"$T/ttlbin/closer" <<'EOF'
#!/bin/sh
printf 'closed %s\n' "$1" >>"$CLOSELOG"
EOF
chmod +x "$T/ttlbin/closer"
mkdir -p "$T/run/agent-state/global"
ttlemit() {
	: >"$CLOSELOG"
	env XDG_RUNTIME_DIR="$T/run" TMUX=/tmp/fake/global,1,0 TMUX_PANE=%40 \
	MUX_NOTIFY_CLOSE="$T/ttlbin/closer" PATH="$T/ttlbin:$PATH" \
	"$HERE/libexec/agent-state-emit" "$@" >/dev/null 2>&1
}

# A FRESH id is still closed on a real state change. This is the behaviour the
# TTL must not break.
_now=$(date +%s)
printf 'idle 0 %%40 %s 522 charon\n' "$_now" >"$T/run/agent-state/global/40"
ttlemit working
grep -qx 'closed 522' "$CLOSELOG" \
	|| fail "a fresh id was not closed on a state change: [$(cat "$CLOSELOG")]"

# A STALE id must be dropped silently, never handed to the closer.
printf 'idle 0 %%40 %s 522 charon\n' "$((_now - 200000))" \
	>"$T/run/agent-state/global/40"
ttlemit working
[ ! -s "$CLOSELOG" ] \
	|| fail "a 55-hour-old id was closed: [$(cat "$CLOSELOG")]"
# ... and it is not carried into the new record either.
_n=$(cut -d' ' -f5 <"$T/run/agent-state/global/40")
[ "$_n" = - ] || fail "a stale id survived into the record: [$_n]"

# The window is configurable, and the boundary is respected.
printf 'idle 0 %%40 %s 522 charon\n' "$((_now - 10))" \
	>"$T/run/agent-state/global/40"
MUX_NOTIF_TTL=5 ttlemit working
[ ! -s "$CLOSELOG" ] \
	|| fail "MUX_NOTIF_TTL was ignored: [$(cat "$CLOSELOG")]"

pass
