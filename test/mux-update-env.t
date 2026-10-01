#!/bin/sh
# test/mux-update-env.t - `mux update-env`, the verb that reaches LIVE sessions.
#
# WHY THIS FILE EXISTS AT ALL, which is the uncomfortable half: the verb
# shipped in 0.85 with NO test and no corpus record, 260 lines of product. It
# was found out the way this package keeps finding things out, by running it
# against the real machine and reading the output, and the first thing the
# output said was wrong.
#
# THE BUG IT WAS WRONG ABOUT is the one the first case here pins. The stale
# walk compared each pane against the NAME LIST, so every pane was reported
# stale for a name mux had DELIBERATELY WITHHELD: 18 panes on this box named
# for WAYLAND_DISPLAY, which nothing on it listens to, advising a restart that
# could never supply it, in the same breath as a real finding about
# SSH_AUTH_SOCK. The comparison has to be against what the SESSION now holds.
#
# DRIVES A REAL TMUX, and must: the subject is the relationship between a
# session's environment and a running pane's /proc/<pid>/environ, and neither
# of those is a thing a stub tmux has.
set -eu
_name=mux-update-env
. "$(dirname "$0")/harness_lib"

command -v tmux >/dev/null 2>&1 || {
  printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

PATH=$HERE/bin:$PATH; export PATH
MUX_DIR=$T/conf
# PINNED EMPTY, because names are the UNION of both envhooks.d directories.
# Without this the four SHIPPED hooks join every plan and their validators
# probe the developer's own sockets, so the fixture measures the machine.
MUX_SHARE=$T/noshare
MUX_STATE=$T/state
MUX_CACHE=$T/cache
export MUX_DIR MUX_SHARE MUX_STATE MUX_CACHE
mkdir -p "$MUX_DIR/envhooks.d" "$MUX_SHARE" "$MUX_STATE" "$MUX_CACHE"

printf '#!/bin/sh\nexit 0\n' >"$MUX_DIR/envhooks.d/MUX_T_LIVE"
printf '#!/bin/sh\nexit 1\n' >"$MUX_DIR/envhooks.d/MUX_T_DEAD"
chmod +x "$MUX_DIR/envhooks.d"/*

SOCK=
cleanup() { [ -z "$SOCK" ] || tmux_drop_socket "$SOCK"; }
t_trap 'cleanup'

# --- the refusals, which need no server -----------------------------------
# FIRST, because `test/mutate` copies the tree without .git and anything after
# a skip is unreachable to the corpus. The same ordering lesson the homebrew
# test paid for: in a test with an early skip, put what needs nothing first.

_rc=0; _o=$(mux update-env --all x:y 2>&1) || _rc=$?
[ "$_rc" -eq 2 ] || fail "--all and an address contradict each other and must
be refused, not silently resolved to one of them: rc=$_rc [$_o]"

_rc=0; _o=$(mux update-env 'a:b:2' 2>&1) || _rc=$?
[ "$_rc" -eq 2 ] || fail "a WINDOW field must be refused: tmux keeps an
environment per session and per server, so accepting it would be a field that
parses and does nothing. rc=$_rc [$_o]"
case $_o in
*'a:b'*) ;;
*) fail "the window refusal must print the address WITHOUT the window field,
so the remedy is in the refusal rather than left as an exercise: [$_o]" ;;
esac

_rc=0; _o=$(env -u TMUX mux update-env 2>&1) || _rc=$?
[ "$_rc" -eq 2 ] || fail "outside any session and with no --all there is no
subject at all, and that must say so rather than SILENTLY WIDENING to every
session, which would act on sessions the caller never named: rc=$_rc [$_o]"
case $_o in
*--all*) ;;
*) fail "the no-subject refusal must name --all, since that is the thing the
caller probably wanted: [$_o]" ;;
esac

# --- everything below needs a real server ---------------------------------
SOCK=$(tmux_fresh_socket muxupd)
tm() { tmux -L "$SOCK" "$@"; }

# THE PANE IS CREATED WITHOUT THE NAME IN ITS ENVIRONMENT, which is the whole
# fixture: a pane is stale precisely when it predates the value. `env -u` on
# the server start is what makes that true, because a tmux server hands its
# own environment to every pane it creates.
env -u TMUX -u TMUX_PANE -u MUX_T_LIVE -u MUX_T_DEAD \
  tmux -L "$SOCK" -f /dev/null new-session -d -s one -x 80 -y 24 \
  || { printf 'skip %s (cannot start a tmux server)\n' "$_name"; exit 0; }

MUX_T_LIVE=/a/live/value; export MUX_T_LIVE
MUX_T_DEAD=/a/dead/value; export MUX_T_DEAD

# --- a dry run must change nothing ----------------------------------------
# Asserted on the SESSION rather than on the output, because "would set" is
# equally printable by a run that also set it.
# The session is given a value whose own validator calls it dead, so the
# preview has a DROP in it as well as a SET: the drop is the arm that exposed
# the tense bug and `set` is the one word that hides it.
tm set-environment -t '=one' MUX_T_DEAD /a/dead/value
_o=$(mux update-env "$SOCK:one" -n 2>&1 || true)
case $_o in
*'would set MUX_T_LIVE'*) ;;
*) fail "a dry run must say what it WOULD do: [$_o]" ;;
esac
case $_o in
*'would drop MUX_T_DEAD'*) ;;
*'would dropped'*) fail "the preview prefixes 'would ' onto the PAST tense
mux_env_apply reports, so it reads 'would dropped X'. Seen on a live box.
Only 'set' works in both tenses, which is why this looked right: [$_o]" ;;
*) fail "a dead value already in the session must appear in the preview as a
DROP, or the preview is not showing the whole decision: [$_o]" ;;
esac
case $(tm show-environment -t '=one' MUX_T_LIVE 2>&1) in
*'unknown variable'*) ;;
*) fail "a DRY RUN WROTE TO THE SESSION, which makes -n worse than useless:
a preview the caller trusted has already acted" ;;
esac

# --- the real run ---------------------------------------------------------
_o=$(mux update-env "$SOCK:one" 2>&1 || true)
[ "$(tm show-environment -t '=one' MUX_T_LIVE)" = "MUX_T_LIVE=/a/live/value" ] \
  || fail "a live session was not repaired, which is the entire reason this
verb exists: without it the remedy for a poisoned box is killing the server.
[$(tm show-environment -t '=one' MUX_T_LIVE 2>&1)]"

case $(tm show-environment -t '=one' MUX_T_DEAD 2>&1) in
*'unknown variable'*) ;;
*) fail "a value whose own validator says it is dead was written into the
session anyway, so this verb propagates the fault it exists to repair" ;;
esac

# --- THE LOAD-BEARING CASE: stale is relative to the SESSION --------------
# TWO ASSERTIONS, NOT ONE, and deliberately so: each direction is a different
# bug and a single "the report mentions something" check kills neither.
#
#   naming MUX_T_LIVE   is the real finding, and losing it would make
#                       `updated` read as "your running agent is fixed"
#   naming MUX_T_DEAD   is the bug found live: advice to restart a pane for
#                       something no restart can ever supply
# SCOPED TO THE STALE SECTION, because the output carries TWO reports and
# they are different kinds of fact: what was changed, then what cannot be.
# Matching the whole thing made this assertion read the apply report's own
# `dropped MUX_T_DEAD` line as a stale-pane finding, so it failed against
# correct code. The product already draws this line; the test has to too.
_stale=$(printf '%s\n' "$_o" | sed -n '/still on the OLD/,$p')
if [ -r /proc/$$/environ ]; then
  [ -n "$_stale" ] || fail "no stale-pane section at all, so the two
assertions below would both pass against a verb that said nothing: [$_o]"
  case $_stale in
  *MUX_T_LIVE*) ;;
  *) fail "the pane predates the value and can never gain it, so it must be
NAMED: a process environment is fixed at exec, and reporting only what was
set invites the reader to think their running agent was repaired.
[$_stale]" ;;
  esac
  case $_stale in
  *MUX_T_DEAD*)
    fail "a pane was reported stale for a name mux DELIBERATELY WITHHELD. The
session does not hold it and never will, so there is nothing a restart could
supply; printing it beside a real finding is advice that cannot come true,
which is this package's oldest defect class. [$_stale]" ;;
  esac
else
  printf 'note %s: no readable /proc, stale-pane cases skipped\n' "$_name"
fi

# --- idempotence ----------------------------------------------------------
# A second run must find nothing to do. R9 is what makes this true: the verb
# acts only where a session LACKS a working value, so convergence is not a
# thing it keeps re-asserting.
_o2=$(mux update-env "$SOCK:one" 2>&1 || true)
case $_o2 in
*'nothing needed changing'*) ;;
*) fail "a second run changed something, so this verb is not idempotent and
cannot be run from a provisioner or a hook: [$_o2]" ;;
esac

# --- a session that is not there ------------------------------------------
_o=$(mux update-env "$SOCK:nosuch" 2>&1 || true)
case $_o in
*'no such session'*) ;;
*) fail "naming a session that does not exist must say so: [$_o]" ;;
esac

pass
