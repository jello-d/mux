#!/bin/sh
# test/mux-demo.t - the throwaway demo, and the isolation that makes it safe to
# ship.
#
# THE LOAD-BEARING PROPERTY IS NOT THAT IT WORKS, IT IS THAT IT CANNOT REACH
# ANYTHING REAL. A demo that ships with mux runs on a machine with real sessions
# on it, and the failure nobody would forgive is a pretend agent writing a
# record a real strip reads, or `--stop` killing a server somebody was using.
# So most of this file is about what the demo must NOT touch.
#
# It drives a REAL tmux (the fake agents have to run somewhere), so it follows
# this suite's rule for that: a fresh socket name per run, never reused, because
# `kill-server` returns before the server is gone and the next create races the
# teardown.
set -eu
_name=mux-demo
. "$(dirname "$0")/harness_lib"

command -v tmux >/dev/null 2>&1 || {
  printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

# Its own runtime dir as well as its own socket, so an assertion about what the
# demo wrote cannot be confused by anything already on this machine.
XDG_RUNTIME_DIR=$T/run; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
SOCK=$(tmux_fresh_socket mux.demotest)
demo() { env -u MUX_SHARE MUX_DEMO_SOCKET="$SOCK" "$HERE/bin/mux" demo "$@"; }
cleanup() { tmux_drop_socket "$SOCK"; }
trap 'cleanup' EXIT INT TERM

_until() {   # <seconds> <command...>
  _lim=$(( ${1} * 20 )); shift
  _n=0
  while [ "$_n" -lt "$_lim" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
    _n=$((_n + 1))
  done
  return 1
}

# --- stopping something that was never started is not an error -------------
# `--stop` is what the banner tells a user to run, so it has to be safe to run
# twice, or from a shell that never started one.
_o=$(demo --stop 2>&1) || fail "--stop on nothing failed: $_o"
case $_o in
*"no demo server"*) ;;
*) fail "--stop on nothing should say so plainly: [$_o]" ;;
esac

# --- it builds, on its own socket -----------------------------------------
_o=$(demo --no-attach 2>&1) || fail "build failed: $_o"
for _s in api web docs infra; do
  tmux -L "$SOCK" has-session -t "$_s" 2>/dev/null \
    || fail "session $_s was not created"
done

# THE BANNER HAS TO SAY HOW TO LEAVE AND HOW TO STOP. A throwaway the user
# cannot get out of is not a throwaway, and this is the one piece of text they
# will actually read.
for _want in 'prefix b' 'prefix d' 'mux demo --stop'; do
  case $_o in
  *"$_want"*) ;;
  *) fail "the banner never mentions [$_want]: [$_o]" ;;
  esac
done

# --- the state it writes is ITS OWN, through mux's real path ---------------
# The fake agents call `mux agent-hook`, so a record appearing at all proves the
# hook table, the emit and the record format are the shipped ones rather than a
# fixture. If this ever needs a fixture to pass, the demo has stopped
# demonstrating mux.
# POLLED ON THE STATE IT NEEDS, not on "a record exists". The first draft waited
# for any record and then read them, which raced: `api` sends
# UserPromptSubmit, sleeps, and only then goes blocked, so the read landed on
# `working` and the assertion failed for a reason that had nothing to do with
# the demo. Wait for the condition under test.
_dir=$XDG_RUNTIME_DIR/agent-state/$SOCK
_blocked() { grep -lq '^blocked ' "$_dir"/* 2>/dev/null; }
_until 20 _blocked || fail "nothing reached \`blocked\`, so \`prefix b\` has no
target and the demo's main claim does not hold. Either the pretend agents are
not reaching mux's hook path, or the event table no longer maps Notification to
blocked. States seen: [$(cat "$_dir"/* 2>/dev/null | awk '{print $1}' \
  | sort -u | tr '\n' ' ')]"

# AND NOTHING ELSE HAS A NAMESPACE HERE. This is the assertion the whole file
# exists for: one directory, named after the demo's own socket.
_ns=$(ls "$XDG_RUNTIME_DIR/agent-state" | tr '\n' ' ')
[ "$_ns" = "$SOCK " ] || fail "the demo wrote outside its own namespace: found
[$_ns], expected only [$SOCK]. A pretend agent must never write a record a real
session reads."

# --- the strip draws it, which is the entire point ------------------------
# Rendered against the demo server, because a demo whose strip is empty has
# nothing to show. The glyph comes from the single source in
# mux-agent-state_lib.
. "$HERE/libexec/mux-agent-state_lib"
_sp=$(tmux -L "$SOCK" display-message -p '#{socket_path}')
_strip=$(env TMUX="$_sp,0,0" MUX_STRIP_WIDTH=140 \
  "$HERE/libexec/mux-agent-state-render" api demo 2>/dev/null \
  | sed 's/#\[[^]]*\]//g')
case $_strip in
*"$MUX_GLYPH_BLOCKED"*) ;;
*) fail "the demo strip shows no blocked glyph: [$_strip]" ;;
esac
for _s in api web docs infra; do
  case $_strip in
  *"$_s"*) ;;
  *) fail "the demo strip omits $_s: [$_strip]" ;;
  esac
done

# --- running it twice attaches rather than complaining --------------------
_o=$(demo --no-attach 2>&1) || fail "second build failed: $_o"
case $_o in
*"already running"*) ;;
*) fail "a second run should say it is already running: [$_o]" ;;
esac

# --- --stop takes the server AND the state -------------------------------
_o=$(demo --stop 2>&1) || fail "--stop failed: $_o"
tmux -L "$SOCK" has-session -t api 2>/dev/null \
  && fail "--stop left the server running"
[ -d "$XDG_RUNTIME_DIR/agent-state/$SOCK" ] && fail "--stop left the demo's
agent state behind, so \`mux agent-doctor\` on that socket would report
findings about a demo nobody is running"

pass
