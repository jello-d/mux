#!/bin/sh
# test/mux-even.t - `mux even`, the put-it-back-to-the-declared-shape verb.
#
# WHY IT EXISTS. `mux refresh` acted on the CURRENT window only, so a row that
# drifted to 79|81 in a session you were not looking at stayed that way, and
# the drift you actually notice is BETWEEN sessions, because borders jump as
# you cycle. Found live: six sessions, five identical, one at 81x53/79x53/161x9
# where the rest were 80x52/80x52/161x10.
#
# AND THE ONE THAT WAS STUCK COULD NOT BE FIXED BY prefix-r OR prefix-R,
# because its bottom pane had lost @mux-bottom. That single missing option
# freezes BOTH halves: `mux pin` skips the pane, and the width balance refuses
# too, since with no marker it cannot tell the bottom pane from the row above,
# sees panes of unequal height, and declines to mangle an arrangement it
# cannot model. One lost option, whole window frozen, nothing said.
#
# Drives a REAL tmux: every assertion here is about geometry tmux computes.
set -eu
_name=mux-even
. "$(dirname "$0")/harness_lib"

command -v tmux >/dev/null 2>&1 || {
  printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

SOCK=$(tmux_fresh_socket muxeven)
PATH=$HERE/bin:$PATH; export PATH
tm() { tmux -L "$SOCK" "$@"; }
cleanup() { tmux_drop_socket "$SOCK"; }
t_trap 'cleanup'

# RUN THROUGH run-shell, which is how the key binding invokes it: a bare
# `mux even` here would talk to the DEFAULT socket, not this test's server,
# and quietly assert nothing about either.
geom() { tm list-panes -t t -F '#{pane_width}x#{pane_height}' | tr '\n' ' '; }

build() {   # a two-up-one-bottom window, the shape mux builds
  cleanup
  SOCK=$(tmux_fresh_socket muxeven)
  tm new-session -d -s t -x 161 -y 63 -c /tmp
  tm split-window -h -t t -c /tmp
  tm select-layout -t t even-horizontal
  tm split-window -v -f -l 10 -t t -c /tmp
  _bot=$(tm list-panes -t t -F '#{pane_id}' | tail -1)
  tm set-option -p -t "$_bot" @mux-bottom 5-10
}

# --- an EVEN window is left alone -----------------------------------------
# The mirror of everything below: a verb that always changed something would
# pass every drift assertion while churning windows that were already right.
build
_before=$(geom)
tm run-shell "mux even" >/dev/null 2>&1 || true
[ "$(geom)" = "$_before" ] \
  || fail "an already-even window was changed: [$_before] -> [$(geom)]"

# --- a DRIFTED row is evened out ------------------------------------------
# The 79|81 case, reproduced by resizing rather than described.
build
tm resize-pane -t t.0 -x 81
_drift=$(geom)
case $_drift in
  "81x"*) ;;
  *) fail "setup: expected a drifted row, got [$_drift]" ;;
esac
tm run-shell "mux even" >/dev/null 2>&1 || true
case $(geom) in
  "80x"*"80x"*) ;;
  *) fail "the drifted row was not evened: [$(geom)]" ;;
esac

# --- A MISSING @mux-bottom IS ADOPTED BACK FROM A SIBLING -----------------
# The live failure. Without the marker neither half can act, so `mux even`
# takes the spec the rest of the server agrees on rather than leaving the
# window frozen, which for a verb whose whole question is "what do the other
# windows agree on" IS the answer, not a guess.
build
tm new-session -d -s other -x 161 -y 63 -c /tmp
tm split-window -v -f -l 10 -t other -c /tmp
_ob=$(tm list-panes -t other -F '#{pane_id}' | tail -1)
tm set-option -p -t "$_ob" @mux-bottom 5-10     # the sibling with the answer

_bot=$(tm list-panes -t t -F '#{pane_id}' | tail -1)
tm set-option -pu -t "$_bot" @mux-bottom        # ... and t has lost its own
[ -z "$(tm show-options -pqv -t "$_bot" @mux-bottom)" ] \
  || fail "setup: the marker was not actually cleared"

tm run-shell "mux even --all" >/dev/null 2>&1 || true
[ "$(tm show-options -pqv -t "$_bot" @mux-bottom)" = 5-10 ] \
  || fail "a window that lost @mux-bottom was left frozen: nothing can
hold its height, and the width balance refuses too, so prefix-r and prefix-R
both silently do nothing for it"

# --- with NOTHING to learn from, it does not invent a spec ----------------
# The other direction, and it has to be asserted separately: adopting a
# sibling's value is right, making one up is not: an invented height would
# cement whatever drift is already there.
build
_bot=$(tm list-panes -t t -F '#{pane_id}' | tail -1)
tm set-option -pu -t "$_bot" @mux-bottom
# Run it DIRECTLY with $TMUX pointed at this server, so stderr can be read.
# Through run-shell the message is tmux's to swallow, and the message is the
# only observable here: setting the option to an EMPTY value looks identical
# to not setting it at all when read back, so asserting on show-options
# cannot tell the two apart. Mutation said so.
_sp=$(tm display-message -p '#{socket_path}')
_o=$(env TMUX="$_sp,0,0" "$HERE/libexec/mux-even" --all 2>&1 || true)
case $_o in
  *"no @mux-bottom"*) ;;
  *"restored"*) fail "with no sibling to copy, it claimed to restore a spec
it could not have known: [$_o]" ;;
  *) fail "with no sibling to copy, it said nothing about the frozen
window: [$_o]" ;;
esac

# --- --all reaches a window that is not the current one -------------------
# The whole point of the verb. Asserted on a session the client is NOT looking
# at, because the single-window form would pass any assertion made about the
# active one.
build
tm new-session -d -s far -x 161 -y 63 -c /tmp
tm split-window -h -t far -c /tmp
tm select-layout -t far even-horizontal
tm resize-pane -t far.0 -x 100
case $(tm list-panes -t far -F '#{pane_width}' | tr '\n' ' ') in
  "100 "*) ;;
  *) fail "setup: the far session did not drift" ;;
esac
# A DECOY SESSION, CREATED AFTER `far`, AND IT IS THE WHOLE ASSERTION. Until it
# existed this case said what it meant and proved none of it: `far` was the
# newest session, so it WAS the current window, and a `mux even` reduced to the
# current window alone still evened it and still passed. The mutation survived
# the full corpus run on 2026-09-29: the comment above described an intent the
# fixture did not implement, the same shape as the mark's font claiming to be
# condensed for three releases.
#
# MEASURED, after two plausible fixes were wrong. With no client attached,
# tmux's default target is the MOST RECENTLY CREATED session, and `run-shell`
# exports NO TMUX_PANE to its child at all, so `run-shell -t t` cannot steer
# what a later `tmux display-message` inside that child resolves, and a fix
# built on it was inert while looking correct. The only thing that moves the
# default target off `far` is a session newer than it.
#
# (The first probe of this was itself contaminated: run from a real tmux, the
# agent's own TMUX_PANE=%1 leaked in and happened to name a pane on the scratch
# server. Same hole harness_lib closed this morning, met again in a diagnostic.)
tm new-session -d -s decoy -x 161 -y 63 -c /tmp
tm run-shell "mux even --all" >/dev/null 2>&1 || true
case $(tm list-panes -t far -F '#{pane_width}' | tr '\n' ' ') in
  "80 80 ") ;;
  *) fail "--all did not reach a session the client is not on: [$(tm \
list-panes -t far -F '#{pane_width}' | tr '\n' ' ')]" ;;
esac

# --- HEADLESS: outside tmux it must still reach the right server ----------
# `mux even` is mostly a key binding, so the case that works hid the one that
# did not: every tmux call was bare, which outside tmux reaches the DEFAULT
# socket. `mux even --all` from a shell therefore found no windows and exited
# 0 having done nothing: silent, and indistinguishable from "already tidy".
# Headless the socket comes from MUX_CTX_PARTITION, which is the partition
# this verb is scoped to.
build
tm resize-pane -t t.0 -x 81
case $(geom) in
  "81x"*) ;;
  *) fail "setup: expected a drifted row, got [$(geom)]" ;;
esac
env -u TMUX MUX_CTX_PARTITION="$SOCK" "$HERE/libexec/mux-even" --all \
  >/dev/null 2>&1 || true
case $(geom) in
  "80x"*"80x"*) ;;
  *) fail "headless did not reach the partition's server: [$(geom)]. It
went to the default socket, found nothing, and exited 0" ;;
esac

# --- the socket FILE goes too, not just the server ------------------------
# `kill-server` returns before the server is gone and the socket lingers for
# seconds after it, which is why every test here takes a FRESH name. That
# dodges the race and does nothing about the LITTER: 123 dead sockets had
# piled up in one day of test runs against 2 live servers, and 247 had been
# swept by hand once before. mux's own rule, turned on its own suite.
_s=$SOCK
cleanup
[ ! -e "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$_s" ] \
  || fail "cleanup killed the server and left its socket behind:
${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$_s. Every run leaks one, forever"
build

# --- an unknown option is an error ----------------------------------------
_rc=0
mux even --nope >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown option must exit 2, got $_rc"

pass
