#!/bin/sh
# test/mux-envhooks.t - the four SHIPPED validators in share/envhooks.d.
#
# WHY THIS FILE EXISTS, and it is the same reason as the last time: the four
# shipped hooks had NEVER EXECUTED IN A TEST. Both files that mention
# envhooks.d write their own scratch hooks, correctly, because they are
# testing the LIBRARY. So the seam was proven and the shipped implementation
# of it had never run, which is this package's most repeated finding (both
# latch hooks were dark the same way, and so was the indicator's transport
# config key).
#
# IT COST A REAL BUG, found by running `mux update-env` against a live
# desktop rather than by any assertion here: the WAYLAND_DISPLAY hook asked
# `wayland-info` about the hook's OWN environment rather than about the value
# it was handed, so with WAYLAND_DISPLAY unset (a login shell over ssh, a
# systemd unit, an agent pane) it probed `wayland-0`, found nothing, and
# reported a live `wayland-1` as dead. `mux update-env --all` would then have
# REMOVED a working display from every session on the box.
#
# THE CONTRACT UNDER TEST IS THREE-ANSWERED, and the third answer is the
# point: 0 live, 1 DEAD, 2 CANNOT TELL. mux must never read 2 as dead, so a
# hook with no tool available has to say 2 and not guess. Every case below
# names which of the three it is asserting.
set -eu
_name=mux-envhooks
. "$(dirname "$0")/harness_lib"

H=$HERE/share/envhooks.d
for _h in SSH_AUTH_SOCK XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS \
          WAYLAND_DISPLAY; do
  [ -x "$H/$_h" ] || fail "share/envhooks.d/$_h is missing or not executable,
so mux ships a name it cannot judge and every value for it reads as
undetermined"
done

# `run` keeps the hook's own exit code, which a pipe would eat. That trap has
# cost this session three wrong readings, so it is not done here.
run() {   # <hook> [value...]
  _rc=0
  env -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR \
    "$H/$1" ${2+"$2"} >/dev/null 2>&1 || _rc=$?
  printf '%s' "$_rc"
}

# A socket FILE with nobody behind it, which is the shape every presence test
# gets wrong: a unix socket outlives its listener.
_mkso=$T/mksock.py
cat >"$_mkso" <<'PY'
import socket, sys, os
for p in sys.argv[1:]:
    if os.path.exists(p):
        os.unlink(p)
    s = socket.socket(socket.AF_UNIX)
    s.bind(p)
    s.close()
PY
python3 "$_mkso" "$T/dead.sock" "$T/wayland-7" 2>/dev/null || {
  printf 'skip %s (no python3 to make a socket)\n' "$_name"; exit 0; }

# --- SSH_AUTH_SOCK: presence, and that is DELIBERATELY lenient -------------
# It answers on `[ -S ]` while its sibling argues a presence test is not
# enough, and the asymmetry is on purpose: for an agent socket a false LIVE
# costs one honest "could not open a connection to your authentication
# agent", while a false DEAD withholds a working socket from every session.
# Presence errs in the lenient direction, which is the safe one here.
[ "$(run SSH_AUTH_SOCK "$T/dead.sock")" = 0 ] \
  || fail "SSH_AUTH_SOCK must accept a socket that exists: the hook is
deliberately lenient, and tightening it is a change with its own measurement"
[ "$(run SSH_AUTH_SOCK "$T/nope.sock")" = 1 ] \
  || fail "SSH_AUTH_SOCK must call an absent socket DEAD (1), or mux will
propagate a pointer to nothing into every new session"
printf 'x' >"$T/plain"
[ "$(run SSH_AUTH_SOCK "$T/plain")" = 1 ] \
  || fail "a plain FILE is not a socket and must be DEAD (1)"
[ "$(run SSH_AUTH_SOCK)" = 1 ] \
  || fail "an empty value must be DEAD (1), never undetermined"

# --- XDG_RUNTIME_DIR: a directory, and only a directory -------------------
[ "$(run XDG_RUNTIME_DIR "$T")" = 0 ] || fail "an existing directory is live"
[ "$(run XDG_RUNTIME_DIR "$T/plain")" = 1 ] \
  || fail "a FILE is not a runtime directory and must be DEAD (1)"
[ "$(run XDG_RUNTIME_DIR "$T/nothing-here")" = 1 ] \
  || fail "an absent path must be DEAD (1)"

# --- DBUS_SESSION_BUS_ADDRESS: three answers, all three reachable ---------
# THIS HOOK IS THE CLEAREST CASE FOR THE THIRD ANSWER, which is why each arm
# is asserted separately rather than as "it did not say 0".
[ "$(run DBUS_SESSION_BUS_ADDRESS "unix:path=$T/dead.sock")" = 0 ] \
  || fail "a unix:path= address whose socket exists must be live"
[ "$(run DBUS_SESSION_BUS_ADDRESS "unix:path=$T/dead.sock,guid=ab12")" = 0 ] \
  || fail "a real bus address carries more fields after the path and the hook
must read only the path: dbus writes unix:path=/run/user/1000/bus,guid=..."
[ "$(run DBUS_SESSION_BUS_ADDRESS "unix:path=$T/gone")" = 1 ] \
  || fail "a unix:path= address pointing at nothing must be DEAD (1)"
[ "$(run DBUS_SESSION_BUS_ADDRESS 'unix:abstract=/tmp/dbus-xyz')" = 2 ] \
  || fail "an ABSTRACT socket has no filesystem entry to test, so the only
honest answer is CANNOT TELL (2). Answering 1 would make mux withhold a
perfectly good bus address on any system that uses them"
[ "$(run DBUS_SESSION_BUS_ADDRESS 'tcp:host=localhost,port=1')" = 2 ] \
  || fail "a transport this hook does not understand must be CANNOT TELL (2),
not dead: the hook's ignorance is not evidence about the bus"
[ "$(run DBUS_SESSION_BUS_ADDRESS)" = 1 ] \
  || fail "an empty value must be DEAD (1)"

# --- WAYLAND_DISPLAY -------------------------------------------------------
# A NAME, NOT A PATH, so it needs another variable's value to become one.
[ "$(run WAYLAND_DISPLAY)" = 1 ] || fail "an empty display must be DEAD (1)"
MUX_RESOLVED_XDG_RUNTIME_DIR=$T; export MUX_RESOLVED_XDG_RUNTIME_DIR
[ "$(run WAYLAND_DISPLAY nothing-here)" = 1 ] \
  || fail "a display name with no socket at all must be DEAD (1)"

# THE REGRESSION, AND THE ONE ASSERTION IN THIS FILE THAT COST A BUG.
# Asserted on WHAT THE TOOL WAS ASKED, not on the verdict: a hook that
# probed the wrong display would still answer 0 on a box whose live display
# happens to be the one in the environment, so an outcome check passes on
# the broken code. Same reasoning as asserting the argv of the BSD `script`
# arm rather than its output.
mkdir -p "$T/bin"
cat >"$T/bin/wayland-info" <<'STUB'
#!/bin/sh
printf '%s\n' "${WAYLAND_DISPLAY:-(unset)}" >"$MUX_T_ASKED"
exit 0
STUB
chmod +x "$T/bin/wayland-info"
MUX_T_ASKED=$T/asked; export MUX_T_ASKED
# A CURATED PATH, so the stub is the only wayland-info and `nc` cannot be
# picked instead: the technique this suite already uses in mux-check.t.
mkdir -p "$T/curated"
for _t in sh env printf command timeout; do
  _p=$(command -v "$_t" 2>/dev/null) || continue
  ln -sf "$_p" "$T/curated/$_t" 2>/dev/null || true
done
ln -sf "$T/bin/wayland-info" "$T/curated/wayland-info"
_rc=0
env -u WAYLAND_DISPLAY PATH="$T/curated" MUX_T_ASKED="$T/asked" \
  MUX_RESOLVED_XDG_RUNTIME_DIR="$T" \
  "$H/WAYLAND_DISPLAY" wayland-7 >/dev/null 2>&1 || _rc=$?
[ -s "$T/asked" ] || fail "the hook never ran the connect tool, so this case
proves nothing about which display it probes: [rc=$_rc]"
[ "$(cat "$T/asked")" = wayland-7 ] \
  || fail "THE HOOK PROBED THE WRONG DISPLAY. It asked about
[$(cat "$T/asked")] when it was handed [wayland-7], so it is judging its own
environment rather than the value under test. With WAYLAND_DISPLAY unset (ssh,
a unit, an agent pane) that means reporting a LIVE display dead, and
'mux update-env' then removes a working one from every session."

# --- NO TOOL IS NOT A VERDICT ---------------------------------------------
# The case that must not degrade to a guess: the socket is there and mux has
# no way to ask whether anyone is behind it. 2, never 1.
mkdir -p "$T/bare"
for _t in sh env printf command; do
  _p=$(command -v "$_t" 2>/dev/null) || continue
  ln -sf "$_p" "$T/bare/$_t" 2>/dev/null || true
done
_rc=0
env -u WAYLAND_DISPLAY PATH="$T/bare" \
  MUX_RESOLVED_XDG_RUNTIME_DIR="$T" \
  "$H/WAYLAND_DISPLAY" wayland-7 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "with no connect tool on PATH the socket exists and
nothing can say whether it is served, so the answer is CANNOT TELL (2). This
returned $_rc; reading that as dead makes a box without wayland-info or nc
lose a working display, which is the trap latch's probe already documents
from the other side."

pass
