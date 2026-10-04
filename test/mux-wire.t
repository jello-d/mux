#!/bin/sh
# test/mux-wire.t - mux guarantees its own wiring on a server it acts on.
#
# WHY THIS EXISTS: until R10, a mux install was NOT complete on its own. The
# fragment loaded only because the user's ~/.config/tmux/tmux.conf carried a
# `source-file` line for it, and on the fleet mux was extracted from, that file
# belongs to the PROVISIONER. Remove that project and mux's bindings, status
# strip and hooks stop loading, while `mux reload` refused outright because it
# required the same foreign file.
#
# THIS DRIVES A REAL TMUX, and that is not a preference. Every property here is
# a property of tmux itself: whether sourcing into a RUNNING server is
# equivalent to booting with it, whether a probe SPAWNS a server, and whether
# re-sourcing an idempotent fragment is free. A stub would be a second model of
# all three, and the stub is what would be wrong.
#
# It SKIPS where tmux is absent, the same as test/lint.t without shellcheck.
set -eu
_name=mux-wire
. "$(dirname "$0")/harness_lib"

command -v tmux >/dev/null 2>&1 || {
  printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

MUX_SHARE=$HERE/share
MUX_VERSION=$(sed -n 's/^MUX_VERSION=//p' "$HERE/bin/mux")
[ -n "$MUX_VERSION" ] || fail "could not read MUX_VERSION out of bin/mux"
PATH=$HERE/bin:$PATH; export PATH

# THE FUNCTIONS ARE LIFTED OUT OF THE SOURCE rather than reimplemented, for the
# reason mux-undo-pane.t gives about `_unquote`: a second copy in the test is a
# second thing to drift. bin/mux is a command, so sourcing it would run it.
eval "$(sed -n '/^mux_wire() {/,/^}/p' "$HERE/bin/mux")"
eval "$(sed -n '/^_reload_one() {/,/^}/p' "$HERE/bin/mux")"

SOCK=
cleanup() { [ -z "$SOCK" ] || tmux_drop_socket "$SOCK"; }
t_trap 'cleanup'

# A server with NO config of any kind, which is the whole point: `-f /dev/null`
# is the post-provisioner world, where nothing else sources mux.tmux.
fresh() {
  [ -z "$SOCK" ] || tmux_drop_socket "$SOCK"
  SOCK=$(tmux_fresh_socket muxwire)
  sock=$SOCK
  env -u TMUX -u TMUX_PANE tmux -L "$SOCK" -f /dev/null \
    new-session -d -s bare -x 120 -y 40
}
tm() { tmux -L "$sock" "$@"; }

wired() {   # is mux's fragment in force on this server?
  # THE BINDING MUST MENTION MUX, not merely EXIST, and that is this
  # package's own rule being relearned: `mux check`'s contract says it
  # outright, that `(` is bound by DEFAULT so asserting the key exists
  # proves nothing. This asked whether `prefix u` was bound at all, which
  # is true on a bare tmux 3.7 (the macOS runner) and false on 3.4 and 3.6,
  # so the precondition "a bare server is not wired" failed on macOS only
  # and read as mux wiring a server it had never touched.
  tmux -L "$SOCK" list-keys -T prefix 2>/dev/null | grep -q mux
}
# AND A SEPARATE PROBE FOR ONE SPECIFIC BINDING, because `wired` and "did a
# re-source happen" are two different questions and sharing a probe between
# them is what broke when `wired` was widened: the skip case removes `prefix u`
# and asserts it STAYS removed, which a whole-server test can never show while
# any other mux binding is present. One arm per question.
ubound() {   # is `prefix u` bound to MUX specifically?
  # THE WHOLE TABLE IS LISTED AND FILTERED, never queried by key, because
  # `list-keys -T prefix u` returns NOTHING on tmux 3.7c while the binding is
  # plainly there: the macOS runner reported `prefix u: []` beside
  # `mux binds: [8]` and a correctly advanced marker. Asking for one key by
  # name is a version-dependent interface; listing the table is not.
  tmux -L "$SOCK" list-keys -T prefix 2>/dev/null \
    | awk '$4 == "u" && /mux/ { f = 1 } END { exit !f }'
}
marker() { tmux -L "$SOCK" show-options -gqv @mux-wired 2>/dev/null || true; }

# --- a server with no mux config at all gets fully wired ------------------
# FOUR SEPARATE PROPERTIES, not one "it worked", because the fragment reaches
# the server through four independent mechanisms and a single assertion would
# be killed by none of them individually. This is the two-guards rule that
# this package has now met seven times.
fresh
wired && fail "the bare server already had mux's bindings, so every
assertion below would pass whatever mux_wire did"

# AND `wired` MUST NOT BE FOOLED BY A BINDING THAT IS MERELY PRESENT, which is
# the macOS condition reproduced LOCALLY rather than waited for: `prefix u` is
# bound by default on the runner's tmux and not on 3.4 or 3.6, so the first
# version of this helper (does `list-keys -T prefix u` succeed?) answered TRUE
# on a bare server there and the precondition above failed on one platform
# only. Measured both ways against a stand-in for that tmux: old helper TRUE,
# new helper false. The rule is already in these notes for `mux check`, where
# `(` is bound by default and so asserting the key exists proves nothing.
# THE STAND-IN COMMAND MUST NOT CONTAIN THE WORD, which caught me: the first
# version bound `display-message 'not mux'` and `wired` matched the FIXTURE's
# own text rather than a binding.
tmux -L "$SOCK" bind -T prefix u display-message hello
wired && fail "a binding that merely EXISTS was read as mux's wiring, so this
file would pass on any tmux whose defaults happen to include one of mux's
keys, and fail on the ones where they do not"
tmux -L "$SOCK" unbind -T prefix u
[ -z "$(marker)" ] \
  || fail "a bare server already carries @mux-wired [$(marker)]"

mux_wire || fail "mux_wire failed on a bare server"

wired || fail "mux_wire did not install mux's key bindings"
case $(tmux -L "$SOCK" show-options -gv status-right) in
*mux*) ;;
*) fail "mux_wire did not take over status-right, so the agent strip would
never draw: [$(tmux -L "$SOCK" show-options -gv status-right)]" ;;
esac
_lh=$(tmux -L "$SOCK" show-hooks -g window-layout-changed 2>/dev/null | wc -l)
[ "$_lh" -ge 4 ] || fail "mux_wire installed $_lh window-layout-changed hooks,
so mux pin and the undo-pane trackers are absent"
[ "$(marker)" = "$MUX_VERSION" ] \
  || fail "the marker says [$(marker)], want [$MUX_VERSION]"

# --- ALREADY WIRED AT THIS VERSION IS A SKIP -----------------------------
# Asserted by REMOVING a binding and checking it stays removed, which is the
# only observable difference between skipping and re-sourcing: the fragment is
# idempotent, so a needless re-source is invisible to any other check.
tmux -L "$SOCK" unbind -T prefix u
mux_wire || fail "mux_wire failed on an already-wired server"
ubound && fail "mux_wire re-sourced a server already at $MUX_VERSION: the
version marker is not being consulted, so every session-affecting verb pays a
source-file it does not need.
  the u row: [$(tmux -L "$SOCK" list-keys -T prefix 2>/dev/null \
               | awk '$4 == "u"')]
  tmux:     [$(tmux -V)]"

# --- A MARKER FROM AN OLDER MUX RE-SOURCES -------------------------------
# THE STALENESS CASE, and it closes a bug this package shipped: `mux check`
# once told a live server to source a fragment it had already sourced, because
# the server predated a newly added binding and nothing could tell. A literal
# marker would have the same hole; the version is what makes it detectable.
tmux -L "$SOCK" set -g @mux-wired 0.01
mux_wire || fail "mux_wire failed over a stale marker"
ubound || fail "mux_wire did not re-source a server whose marker (0.01) is
older than this mux, so an upgrade leaves a live server on the old fragment.
  marker now:  [$(marker)]  (want $MUX_VERSION)
  the u row:   [$(tmux -L "$SOCK" list-keys -T prefix 2>/dev/null \
                 | awk '$4 == "u"')]
  mux binds:   [$(tmux -L "$SOCK" list-keys -T prefix 2>/dev/null \
                  | grep -c mux)]
  tmux:        [$(tmux -V)]"
[ "$(marker)" = "$MUX_VERSION" ] \
  || fail "the stale marker was not advanced: [$(marker)]"

# --- THE PROBE MUST NOT CREATE A SERVER ----------------------------------
# `mux check` had to stop using `list-keys` for exactly this: it SPAWNS a
# server when none is running and then answers out of tmux's defaults. This
# runs on paths where no server may exist yet, so a probe that creates one
# would make mux the cause of the thing it is inspecting.
_gone=$(tmux_fresh_socket muxwiregone)
sock=$_gone
mux_wire || fail "mux_wire must succeed (nothing to do) with no server"
if tmux -L "$_gone" list-sessions >/dev/null 2>&1; then
  tmux_drop_socket "$_gone"
  fail "mux_wire SPAWNED a server just by probing it"
fi
tmux_drop_socket "$_gone"
sock=$SOCK

# --- A FAILED SOURCE IS LOUD, never a silent inert install ---------------
# The worst outcome available here is mux installed and INERT: no strip, no
# bindings, no hooks, and nothing on screen saying why. That is the state this
# package's whole marker contract exists to make impossible.
#
# INDUCED WITH AN UNREADABLE FRAGMENT, which is the one shape that gets past
# `[ -f ]` and still fails. Measured, because the obvious choice does not
# work: tmux `source-file` over a file full of unknown commands prints its
# complaints and exits ZERO, so a syntactically broken fragment would prove
# nothing at all.
fresh
mkdir -p "$T/badshare"
printf 'set -g @x 1\n' >"$T/badshare/mux.tmux"
chmod 000 "$T/badshare/mux.tmux"
_saved=$MUX_SHARE; MUX_SHARE=$T/badshare
_werr=$(mux_wire 2>&1) && fail "mux_wire reported SUCCESS over a fragment it
could not source, so this server has no mux wiring and nothing said so"
MUX_SHARE=$_saved
chmod 644 "$T/badshare/mux.tmux"
case $_werr in
mux:*) ;;
*) fail "mux_wire failed SILENTLY, which leaves mux installed and inert with
no explanation: [$_werr]" ;;
esac

# --- reload: the user's config is OPTIONAL, and mux still wins -----------
# The two halves of R10 in one case. `mux reload` used to exit 1 when
# ~/.config/tmux/tmux.conf was absent, so mux's own verb depended on a file it
# neither ships nor owns.
fresh
TMUX_CONF=$T/nosuchdir/tmux.conf
_reload_one "$SOCK" || fail "reload failed with no user tmux.conf, which is
the dependency R10 removes"
wired || fail "reload exited 0 without sourcing mux's fragment"

# ... and WITH a user config, BOTH load and mux is last.
# ORDER IS THE ASSERTION, not merely presence: the user's prefix key and
# bindings must survive, and a mux binding must win where they collide,
# because that is what lets mux stop claiming the config file at all.
fresh
TMUX_CONF=$T/user-tmux.conf
{ echo 'set -g @from-user-conf yes'
  echo 'bind -T prefix u display "USER WINS"'; } >"$TMUX_CONF"
_reload_one "$SOCK" || fail "reload failed with a user tmux.conf present"
[ "$(tmux -L "$SOCK" show-options -gqv @from-user-conf)" = yes ] \
  || fail "reload did not source the user's own tmux.conf, so their prefix key
and bindings would be lost the moment mux stops relying on that file"
# THROUGH `ubound`, not a single-key query, which is the same
# version-dependent interface that bit the marker pair: `list-keys -T prefix
# u` answers NOTHING on tmux 3.7c while the binding is present. I inspected
# this site when fixing that one and judged it safe because it matches on
# CONTENT (`*mux*`) rather than on existence, which was true about the match
# and missed that the QUERY feeding it was the broken part.
ubound || fail "the USER's binding won prefix-u, so mux's fragment is not
sourced last and a stale binding in their config would shadow a mux verb.
  the u row: [$(tmux -L "$SOCK" list-keys -T prefix 2>/dev/null \
                | awk '$4 == "u"')]
  tmux:      [$(tmux -V)]"

# --- reload must not start a server that was down ------------------------
_down=$(tmux_fresh_socket muxwiredown)
if _reload_one "$_down"; then
  tmux_drop_socket "$_down"
  fail "reload reported success against a socket with no server"
fi
if tmux -L "$_down" list-sessions >/dev/null 2>&1; then
  tmux_drop_socket "$_down"
  fail "reload SPAWNED a server that was not running"
fi
tmux_drop_socket "$_down"

# --- THE ENVIRONMENT IS APPLIED, which is the fix the wiring exists for ---
# R1 and R2. A pane's environment comes from the SERVER, and an agent-less
# attach records a REMOVAL (`-SSH_AUTH_SOCK`) that MASKS the server global, so
# a session can be poisoned into a state no lower layer rescues. This asserts
# the repair through the same function bin/mux calls on both the build and the
# attach path.
#
# DRIVEN WITH A HOOK THAT ALWAYS VALIDATES, not with the real ones: whether
# this box has a live ssh agent is a fact about the box, and a test that
# depends on it measures the machine rather than the code. The shipped
# validators have their own coverage.
fresh
mkdir -p "$T/envconf/envhooks.d"
printf '#!/bin/sh\nexit 0\n' >"$T/envconf/envhooks.d/MUX_T_POINTER"
chmod +x "$T/envconf/envhooks.d/MUX_T_POINTER"
MUX_DIR=$T/envconf
MUX_T_POINTER=/a/resolvable/value; export MUX_T_POINTER
# shellcheck source=/dev/null
. "$HERE/lib/mux-paths_lib"
# shellcheck source=/dev/null
. "$HERE/lib/mux-conf_lib"
# shellcheck source=/dev/null
. "$HERE/lib/mux-notice_lib"
# shellcheck source=/dev/null
. "$HERE/lib/mux-env_lib"

# THE POISONED SESSION, written exactly as tmux writes it: `-NAME` is the
# REMOVAL marker, which is a third state beside set and absent and is the one
# that masks the global.
tmux -L "$SOCK" set-environment -t bare -r MUX_T_POINTER
case $(tmux -L "$SOCK" show-environment -t bare MUX_T_POINTER) in
-MUX_T_POINTER) ;;
*) fail "the fixture did not poison the session, so the assertion below would
pass against a session that was never broken" ;;
esac

mux_env_apply bare >/dev/null 2>&1 || true
[ "$(tmux -L "$SOCK" show-environment -t bare MUX_T_POINTER)" \
  = "MUX_T_POINTER=/a/resolvable/value" ] \
  || fail "a poisoned session was not repaired: [$(tmux -L "$SOCK" \
show-environment -t bare MUX_T_POINTER)]. Every pane created in it from now
on starts without the pointer, which is the whole fault this exists for."

# ... AND A WORKING VALUE IS LEFT ALONE (R9), because converging every session
# onto one answer would make two deliberately different environments collapse
# into each other.
tmux -L "$SOCK" set-environment -t bare MUX_T_POINTER /somebody/elses/choice
mux_env_apply bare >/dev/null 2>&1 || true
[ "$(tmux -L "$SOCK" show-environment -t bare MUX_T_POINTER)" \
  = "MUX_T_POINTER=/somebody/elses/choice" ] \
  || fail "a value that passes its own validator was REPLACED, so a session
with a deliberately different environment cannot survive mux touching it"
unset MUX_T_POINTER

# --- AN INVALID NAME MUST NOT STOP THE ONES AFTER IT --------------------
# THIS TEST FILE RUNS UNDER `set -eu`, which is the whole point of putting the
# case here: so did the callers, and that is what the bug needed.
#
# `mux_env_plan` called its validator bare and then read `$?`. Under `set -e` a
# non-zero return outside a condition context kills the shell, and the loop
# runs inside `$( )`, so the plan TRUNCATED at the first INVALID name and
# every name after it alphabetically was silently never considered. Measured
# four names without `set -e` and two with it.
#
# The ORDER is the fixture: the dead name sorts FIRST, so a truncating loop
# never reaches the live one. Without that, a passing test proves nothing,
# which is how this survived its own non-vacuity check: the hooks it was
# driven with all validated.
fresh
mkdir -p "$T/ordconf/envhooks.d"
printf '#!/bin/sh\nexit 1\n' >"$T/ordconf/envhooks.d/MUX_T_AAA_DEAD"
printf '#!/bin/sh\nexit 0\n' >"$T/ordconf/envhooks.d/MUX_T_ZZZ_LIVE"
chmod +x "$T/ordconf/envhooks.d"/*
MUX_DIR=$T/ordconf
# MUX_SHARE IS PINNED TO AN EMPTY DIRECTORY, which the first version of this
# case did not do and which made its own non-vacuity check unreadable: names
# are the UNION of both envhooks.d directories, so the four SHIPPED names were
# in the plan too, their validators probing this machine's real sockets. The
# count then said 6 here and something else on a box with no wayland.
_ordshare=$MUX_SHARE; MUX_SHARE=$T/noshare
mkdir -p "$MUX_SHARE"
MUX_T_AAA_DEAD=/a/dead/value;  export MUX_T_AAA_DEAD
MUX_T_ZZZ_LIVE=/a/live/value;  export MUX_T_ZZZ_LIVE

_ordn=$(mux_env_plan 2>/dev/null | wc -l)
[ "$_ordn" -eq 2 ] || fail "the plan emitted $_ordn verdicts for two names, so
it stopped early: a name ordered after an INVALID one is never considered, and
mux silently repairs only part of the environment"

# THE SESSION IS POISONED WITH THE DEAD NAME FIRST, because apply only
# validates a value that is ALREADY THERE: with nothing to judge the validator
# is never called, and the apply half of this case was unreachable. The corpus
# said so, by SURVIVING.
tmux -L "$SOCK" set-environment -t bare MUX_T_AAA_DEAD /a/dead/value
# PIPED, NOT `|| true`, and that distinction is the whole reason the first
# version proved nothing. POSIX says `set -e` is IGNORED for the left operand
# of an AND-OR list, so `mux_env_apply ... || true` runs the function with the
# very protection this case exists to remove. `bin/mux` PIPES it into a
# reader, and a pipeline component is a subshell with -e live, so this is
# production's shape. Measured: piped, the mutation applies NOTHING.
mux_env_apply bare -v 2>/dev/null | cat >/dev/null
[ "$(tmux -L "$SOCK" show-environment -t bare MUX_T_ZZZ_LIVE)" \
  = "MUX_T_ZZZ_LIVE=/a/live/value" ] \
  || fail "a valid pointer ordered AFTER an invalid one was not applied, so
one dead value stops the repair for everything alphabetically after it:
[$(tmux -L "$SOCK" show-environment -t bare MUX_T_ZZZ_LIVE 2>&1)]"
unset MUX_T_AAA_DEAD MUX_T_ZZZ_LIVE
MUX_SHARE=$_ordshare


pass
