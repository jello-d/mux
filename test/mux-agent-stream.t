#!/bin/sh
# mux-agent-stream.t - `mux agent stream`: the same document `status` answers,
# one JSON object per LINE, emitted only when something changes.
#
# WHY A STREAM AT ALL. The tray polled every source every 5s over its own ssh,
# so a change took up to five seconds to show and every tick paid a fresh
# connection. Streaming moves the polling ON to the watched box and sends only
# CHANGES, which is also what makes a remote notification possible: the box the
# human is sitting at can finally see transitions as they happen.
#
# EVERY CASE HERE IS BOUNDED, because the thing under test never returns on its
# own. A bare call hung the whole suite once already (test/mux-capabilities.t
# invokes every scraped verb to prove the dispatcher knows it), which is the
# shape test/mutate's own header warns about: a loop whose bound is gone hangs
# the runner instead of failing it.
_name=mux-agent-stream
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/run/mux/agent-state/global"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-clients*)  printf '/dev/pts/0\n' ;;
*list-sessions*) printf 'alpha\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

rec() { printf '%s\t0\t%%1\t100\t-\talpha\n' "$1" \
  >"$T/run/mux/agent-state/global/1"; }

stream() {   # <args...>: run in the background, output to $T/out
  : >"$T/out"
  env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH" \
    "$HERE/bin/mux" agent stream --any "$@" >"$T/out" 2>"$T/serr" &
  _spid=$!
}
stop() { kill "$_spid" 2>/dev/null; wait "$_spid" 2>/dev/null || true; }
# AND FROM THE EXIT TRAP TOO, which is not belt and braces: `fail` EXITS, so
# every assertion that fires skips the `stop` below it and leaves a stream
# running against a scratch directory the harness has just deleted. Harmless
# in a green run and not in a red one, which means a MUTATION RUN leaks one
# per killed record. MEASURED, both ways: a deliberately failing run left
# THREE alive before this line and ZERO after it, and ten were found on this
# box from `/tmp/tmp.*/tree/` copies that no longer existed. Same family as
# the tmux sockets this suite leaked for months, and invisible for the same
# reason: one more anonymous `sh` looks like everybody else's.
t_trap 'kill ${_spid:-0} 2>/dev/null || true'
lines() { wc -l <"$T/out" | tr -d ' '; }

# --- THE FIRST LINE IS THE CURRENT STATE -----------------------------------
# A stream that only spoke on CHANGE would leave every consumer blank until
# something happened, which for a quiet machine is for ever. The tray would
# start empty after each restart and have no way to tell that from "no agents".
rec idle
stream -i 1 --heartbeat 60
sleep 2
[ "$(lines)" -ge 1 ] || fail "nothing was emitted in two seconds: a stream has
to open with the CURRENT state or a consumer is blank until something changes,
which on a quiet machine is indefinitely"
_first=$(head -1 "$T/out")
case $_first in
  *'"status":"ok"'*'"partitions"'*) ;;
  *) fail "the opening line is not the status document: [$_first]" ;;
esac
case $_first in
  *'"state":"idle"'*) ;;
  *) fail "the opening line does not carry the state that is actually set:
[$_first]" ;;
esac

# --- ONE LINE PER CHANGE, AND NOTHING WHILE QUIET --------------------------
# The whole economy of the design: a consumer that must diff every line to
# find out whether anything happened is a poll with extra steps.
_before=$(lines)
sleep 2
[ "$(lines)" = "$_before" ] || fail "the stream emitted while NOTHING changed
(went from $_before to $(lines) lines), so a consumer cannot treat a line as
an event"

rec blocked
sleep 2
[ "$(lines)" -gt "$_before" ] || fail "the record changed to blocked and the
stream said nothing"
case $(tail -1 "$T/out") in
  *'"state":"blocked"'*) ;;
  *) fail "the change was emitted but does not carry the new state:
[$(tail -1 "$T/out")]" ;;
esac

# AND IT IS FULL STATE, NOT A DELTA, which is what lets a consumer attach late
# or reconnect without a resync protocol: every line is the whole answer.
case $(tail -1 "$T/out") in
  *'"partitions":['*) ;;
  *) fail "a change line is not the whole document, so a late subscriber cannot
be correct from one line: [$(tail -1 "$T/out")]" ;;
esac
stop

# --- A HEARTBEAT, BECAUSE QUIET AND DEAD MUST NOT LOOK THE SAME ------------
# The one thing polling gave away for free: there a non-zero exit could only be
# the transport, so `unknown` was trustworthy. A silent stream could be a calm
# host or a wedged ssh, and this package has measured both (a blackholed port,
# and a responsive peer making no progress for 342 seconds).
rec idle
stream -i 1 --heartbeat 2
sleep 5
grep -q '"heartbeat":true' "$T/out" || fail "no heartbeat in five seconds with
a two-second interval: a consumer cannot tell this stream from a dead one, and
that distinction is the only reason UNKNOWN is trustworthy"
# AND A HEARTBEAT IS NOT A CHANGE: a consumer must not redraw on it.
case $(grep '"heartbeat":true' "$T/out" | head -1) in
  *'"partitions"'*) fail "the heartbeat carries a partitions document, so a
consumer cannot tell a keepalive from an event" ;;
esac
stop

# --- IT DIES WITH ITS READER ----------------------------------------------
# Not tidiness: over a transport this is what stops a remote box polling for
# ever after the tray that asked for it went away. The heartbeat is what makes
# it work during quiet periods, since a write is the only way to notice.
# ASKED OF ONE PID, NOT OF THE PROCESS TABLE. The first version counted every
# `mux agent stream` on the box, so a leftover from another run failed it: the
# same global-matching trap as `pgrep` self-matching, which this package has
# recorded three times in other shapes. A FIFO lets the writer be started with
# a known pid and the reader closed independently.
rec idle
mkfifo "$T/fifo" 2>/dev/null || true
env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH" \
  "$HERE/bin/mux" agent stream --any -i 1 --heartbeat 1 2>/dev/null >"$T/fifo" &
_fpid=$!
_out=$(head -1 <"$T/fifo")
[ -n "$_out" ] || fail "precondition: nothing was read, so the exit below
proves nothing about the reader going away"
sleep 3
kill -0 "$_fpid" 2>/dev/null && fail "the stream survived its reader. Over a
transport that is a remote box polling itself for ever after the tray that
asked for it died."
wait "$_fpid" 2>/dev/null || true

# --- ONE PRODUCER, SO THE TWO VERBS CANNOT DISAGREE ------------------------
# `stream` is `status` on a loop. A second copy of the document builder is how
# the polled answer and the streamed one start describing the same instant
# differently, which is the worst bug available in a presenter fed by either.
rec working
_status=$(env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" \
  PATH="$T/bin:$PATH" "$HERE/bin/mux" agent status --any)
stream -i 1 --heartbeat 60
sleep 2
_streamed=$(head -1 "$T/out")
stop
[ "$_status" = "$_streamed" ] || fail "status and stream describe the same
state differently:
  status: [$_status]
  stream: [$_streamed]"

# --- A BAD INTERVAL IS REFUSED, NOT ROUNDED -------------------------------
# A stream is long-lived, so a silently-wrong interval is a cost paid for ever
# rather than once, and `-i 0` is a busy loop on whatever box it runs on.
# BOUNDED, because the guard's ABSENCE hangs rather than fails, and the
# arithmetic is why: `_squiet` advances by `_sint` each tick, so with `-i 0`
# accepted it never reaches the heartbeat, the loop never writes, and a
# never-writing producer never learns its reader has gone. It spins on a dead
# pipe for ever. test/mutate's own header asks for exactly this bound, and the
# driver asked for it again here by killing the mutated run.
for _bad in 0 x -1; do
  _o=$(timeout 5 env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" \
    PATH="$T/bin:$PATH" \
    "$HERE/bin/mux" agent stream --any -i "$_bad" 2>&1 | head -1) || true
  case $_o in
    *'"status":"usage"'*) ;;
    *) fail "an interval of [$_bad] was accepted: [$_o]" ;;
  esac
done

pass
