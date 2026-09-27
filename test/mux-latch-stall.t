#!/bin/sh
# test/mux-latch-stall.t - mux's DEFAULT transport options actually bound a
# stalled peer, at every phase of the ssh handshake.
#
# WHY THIS IS A TEST AND NOT A COMMENT. The options in `_DEF_ALIVE` are the
# only thing standing between a dropped link and latch sleeping forever, and
# for two releases the COMMENT explaining them was wrong in both directions --
# each half generalised from the single peer it had been measured against. A
# comment cannot notice when an option is dropped, reordered or weakened; this
# can.
#
# It reads the defaults OUT OF THE SOURCE rather than restating them, so
# weakening `_DEF_ALIVE` fails here instead of silently passing a test that
# pinned its own copy of the old value.
#
# MEASURED PHASES (2026-09-27), which is why all three are exercised:
#
#   peer stalls at        no timeouts   ConnectTimeout=5   ServerAlive 2 x 2
#   silent (no banner)    hangs         5s                 hangs
#   banner, then stall    hangs         HANGS              4s
#   kexinit, then stall   hangs         HANGS              4s
#
# ConnectTimeout covers only up to RECEIVING the banner; ServerAlive covers
# everything after it. Neither covers the other's column, so a test that used
# one peer would pass with either option deleted.
set -eu
_name=mux-latch-stall
. "$(dirname "$0")/lib.sh"

command -v ssh >/dev/null 2>&1 || {
	printf 'skip %s (no ssh)\n' "$_name"; exit 0; }
command -v python3 >/dev/null 2>&1 || {
	printf 'skip %s (no python3 for the stall peer)\n' "$_name"; exit 0; }

# THE OPTIONS UNDER TEST, taken from the shipped source. Both lines, because
# _DEF_ALIVE is built in two steps and reading only the first would silently
# drop ConnectTimeout -- the very option whose absence this file must catch.
OPTS=$(sed -n "s/^_DEF_ALIVE=['\"]*\(-o [^'\"]*\)['\"]*$/\1/p" \
	"$HERE/libexec/mux-latch" | tr '\n' ' ')
OPTS="$OPTS$(sed -n 's/^_DEF_ALIVE="\$_DEF_ALIVE \(.*\)"$/\1/p' \
	"$HERE/libexec/mux-latch")"
case $OPTS in
*ServerAliveInterval*) ;;
*) fail "could not read ServerAliveInterval out of libexec/mux-latch.
This test reads the defaults from the source on purpose; if the shape of
_DEF_ALIVE changed, update the extraction rather than pinning a copy.
  got: [$OPTS]" ;;
esac
case $OPTS in
*ConnectTimeout*) ;;
*) fail "could not read ConnectTimeout out of libexec/mux-latch: [$OPTS]" ;;
esac

# A peer that stalls at a CHOSEN point. Nothing here speaks ssh: it accepts,
# optionally sends a banner, optionally reads the client's KEXINIT, and then
# goes quiet forever -- which is all three phases a real box can stall in.
cat >"$T/stall.py" <<'PY'
import socket, sys, threading, time
mode, port = sys.argv[1], int(sys.argv[2])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
sys.stderr.write("ready\n"); sys.stderr.flush()
def handle(c):
    try:
        if mode != "silent":
            c.sendall(b"SSH-2.0-OpenSSH_9.6p1 Stall\r\n")
        if mode == "kexinit":
            c.settimeout(10)
            try:
                c.recv(65535)
            except OSError:
                pass
        while True:
            time.sleep(60)
    except OSError:
        pass
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

# Generous, because the point is BOUNDED vs UNBOUNDED, not the exact number.
# The shipped values are ConnectTimeout=10 and 5s x 3, so a real bound lands
# near 10-15s; anything still running at 45s is not slow, it is hung.
CEILING=45
PORT=$((21000 + $$ % 900))

for _mode in silent banner kexinit; do
	PORT=$((PORT + 1))
	python3 "$T/stall.py" "$_mode" "$PORT" 2>"$T/ready" &
	_srv=$!
	# Wait for the listener rather than sleeping: a fixed sleep is either
	# wasted or flaky, and this suite has paid for that before.
	_n=0
	while [ "$_n" -lt 100 ]; do
		grep -q ready "$T/ready" 2>/dev/null && break
		sleep 0.05; _n=$((_n + 1))
	done

	_t0=$(date +%s)
	# `|| _rc=$?`, never a bare call: ssh failing is the EXPECTED outcome
	# here, and under `set -e` a bare invocation takes the whole file down
	# before the next line runs -- no ok, no FAIL, just a silent exit. This
	# file did exactly that on its first run.
	_rc=0
	# shellcheck disable=SC2086   # OPTS is a list of -o flags, split on purpose
	timeout "$CEILING" ssh -p "$PORT" -t $OPTS \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o BatchMode=yes -o PasswordAuthentication=no \
		127.0.0.1 true >/dev/null 2>&1 || _rc=$?
	_el=$(( $(date +%s) - _t0 ))
	kill "$_srv" 2>/dev/null || true

	[ "$_rc" = 124 ] && fail "stalling at [$_mode] was NOT bounded: ssh was
still waiting after ${CEILING}s with mux's shipped transport options.
  options: $OPTS
A peer that accepts and then goes quiet is the disruption latch exists for;
unbounded here means latch is asleep, not slow, and its retry loop never runs."
	[ "$_el" -lt "$CEILING" ] \
		|| fail "[$_mode] took ${_el}s, at the ceiling"
done

pass
