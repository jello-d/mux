#!/bin/sh
# test/mux-undo-pane.t - putting back the pane you closed by accident.
#
# ^D is one keystroke from detach and does something very different. The
# recovery used to be rebuilding the window by hand, which costs every OTHER
# pane's scrollback -- so the accident was expensive out of all proportion.
#
# THIS TEST DRIVES A REAL TMUX SERVER, not the stub the rest of the suite uses,
# and that is deliberate: every property worth having here is a property of tmux
# itself. A stub would be a second model of `select-layout`, and the bugs found
# while building this were all in the real thing's behaviour -- a hook that
# reports the WRONG pane, an asynchronous hook that races the removal it is
# recording, a start command that comes back quoted, and geometry that is
# applied POSITIONALLY. None of those are reachable from a stub.
#
# It SKIPS where tmux is absent, the same as test/lint.t without shellcheck.
set -eu
_name=mux-undo-pane
. "$(dirname "$0")/lib.sh"

command -v tmux >/dev/null 2>&1 || {
	printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

SOCK=muxundo$$
XDG_RUNTIME_DIR=$T/run; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
PATH=$HERE/bin:$PATH; export PATH

tm() { tmux -L "$SOCK" "$@"; }
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap 'cleanup' EXIT INT TERM

# POLLED, NOT SLEPT. Every wait here is for a condition that is observable, so
# waiting for the condition is both faster than a fixed sleep and less flaky
# than one: a sleep long enough to be reliable on a loaded machine is wasted on
# every other run, and a sleep tuned to a fast machine is a test that fails for
# someone else. This turned a 43s file into a few seconds.
_until() {   # <seconds> <command...> -- true as soon as it succeeds
	_lim=$(( ${1} * 20 )); shift
	_n=0
	while [ "$_n" -lt "$_lim" ]; do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 0.05
		_n=$((_n + 1))
	done
	return 1
}
_npanes() { [ "$(tm list-panes -t t 2>/dev/null | wc -l)" = "$1" ]; }
# THE RECORD IS THE REAL PRECONDITION FOR AN UNDO, not the pane count. The pane
# disappears slightly before the hook finishes writing, so polling the count
# alone raced the write and undo found nothing to do -- a window a fixed sleep
# had been hiding. A human pressing prefix-u is far slower than either, so this
# is a test-harness ordering problem rather than a bug, but it is exactly the
# kind a sleep converts into an intermittent failure on someone else's machine.
_recorded() { [ -n "$(ls -A "$T/run/mux-undo" 2>/dev/null)" ]; }
# The shells must have STARTED before their cwd is readable: pane_current_path
# reports the server's directory until then, which silently recorded the wrong
# one the first time this ran by hand.
# ALL THREE, not just the two splits. Waiting only for /etc and /usr let the
# tracker snapshot before pane 0's shell had reported /tmp, so the record
# carried the SERVER's directory and the restore came back in the wrong place.
# Intermittent -- it survived five clean runs before showing up.
_cwds_ready() {
	_cr=$(state)
	case $_cr in *:/tmp*) ;; *) return 1 ;; esac
	case $_cr in *:/etc*) ;; *) return 1 ;; esac
	case $_cr in *:/usr*) ;; *) return 1 ;; esac
	return 0
}

# state: "height:cwd height:cwd ..." top to bottom -- the two things a restore
# has to get right, in the one order that makes a mismatch readable.
state() { tm list-panes -t t -F '#{pane_height}:#{pane_current_path}' \
	2>/dev/null | tr '\n' ' '; }

# build: a three-pane window with a DELIBERATE manual resize, so the saved
# geometry differs from anything `select-layout even-vertical` would produce.
# That is the point of saving the LIVE layout rather than the declared one: if
# the restore quietly re-evened the window, every assertion on a declared
# layout would still pass while the user's arrangement was lost.
build() {
	cleanup
	tm new-session -d -s t -x 120 -y 60 -c /tmp
	tm source-file "$HERE/share/mux.tmux"
	tm split-window -t t -c /etc "echo MARK_A; exec \"\${SHELL:-/bin/sh}\""
	tm split-window -t t -c /usr "echo MARK_B; exec \"\${SHELL:-/bin/sh}\""
	tm select-layout -t t even-vertical
	# ORDER IS LOAD-BEARING: wait for the shells to report their real cwd,
	# and only THEN make a layout event, so the tracker's snapshot is taken
	# after they have settled rather than before.
	_until 10 _cwds_ready || fail "the panes never reported their cwd"
	tm resize-pane -t t.0 -y 30
	_until 5 test -n "$(tm show-options -wqv -t t @mux-ul)" \
		|| fail "the layout tracker never recorded anything"
}

# --- the layout comes back exactly, wherever the hole was -----------------
# All three positions, because the placement logic differs at the ends and
# getting it wrong does NOT look like a missing pane: the window comes back
# with the right COUNT and the panes wearing each other's sizes. A two-pane
# window restored this way had its panes swapped, which is a mismatch a
# count-based assertion sails straight past.
for _slot in 0 1 2; do
	build
	_before=$(state)
	tm send-keys -t "t.$_slot" 'exit' Enter
	_until 10 _npanes 2 \
		|| fail "slot $_slot: the pane did not actually close"
	_until 10 _recorded || fail "slot $_slot: no undo record was written"
	tm run-shell "mux undo-pane" >/dev/null 2>&1 || true
	_until 10 _npanes 3 || fail "slot $_slot: undo restored no pane"
	_until 10 _cwds_ready || true
	_after=$(state)
	[ "$_before" = "$_after" ] || fail "slot $_slot did not come back the
same. The saved layout is applied POSITIONALLY, so a pane created in the wrong
place does not merely sit wrong -- it takes another pane's size.
  before [$_before]
  after  [$_after]"
done

# --- the SURVIVING panes are never touched -------------------------------
# The whole reason this beats rebuilding by hand. Their scrollback is the thing
# that cannot be recreated, so a restore that clears or respawns them would be
# solving the cheap half of the problem.
build
tm send-keys -t t.0 'echo SURVIVOR_SCROLLBACK' Enter
_until 10 sh -c 'tmux -L '"$SOCK"' capture-pane -p -t t.0 |
	grep -q SURVIVOR_SCROLLBACK'
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "the pane did not close"
_until 10 _recorded || fail "no undo record was written"
tm run-shell "mux undo-pane" >/dev/null 2>&1 || true
_until 10 _npanes 3 || fail "undo restored no pane"
tm capture-pane -p -t t.0 | grep -q SURVIVOR_SCROLLBACK \
	|| fail "a surviving pane lost its scrollback. Nothing may be killed or
respawned but the one pane that died."

# --- what it was RUNNING comes back --------------------------------------
# tmux hands `pane_start_command` back QUOTED for display (wrapped, with inner
# quotes and $ escaped). Replaying that verbatim does not fail loudly: the pane
# is created and runs the wrong thing, which is exactly how it survived a first
# live check. This is the assertion that catches a lost unquote.
build
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "the pane did not close"
_until 10 _recorded || fail "no undo record was written"
tm run-shell "mux undo-pane" >/dev/null 2>&1 || true
_until 10 _npanes 3 || fail "undo restored no pane"
_until 10 sh -c 'tmux -L '"$SOCK"' capture-pane -p -t t.1 | grep -q MARK_A'
tm capture-pane -p -t t.1 | grep -q MARK_A \
	|| fail "the restored pane did not re-run its command. An agent pane that
comes back as a bare shell has lost the conversation, which is the case this
feature exists for."

# --- the directory is remembered ------------------------------------------
_until 10 _cwds_ready || true
case "$(state)" in
*":/etc "*) ;;
*) fail "the restored pane did not come back in its old directory: $(state)" ;;
esac

# --- twice is once --------------------------------------------------------
# The record is consumed, so a second undo cannot bolt on a pane nobody lost.
_o=$(tm run-shell "mux undo-pane" 2>&1 || true)
[ "$(tm list-panes -t t | wc -l)" = 3 ] \
	|| fail "a second undo added a pane nobody closed"

# --- ... and so is filling the hole YOURSELF ------------------------------
# The case the consumed record does NOT cover, and the one that needs its own
# guard: close a pane, split a new one by hand, THEN undo. The record is still
# there and looks perfectly valid, but nothing was lost any more. Without the
# check, undo adds a fourth pane and then applies a three-pane layout to it.
#
# Found by mutation: the guard SURVIVED, because the assertion above reaches it
# through the deleted-record path instead and proves nothing about it.
build
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "the pane did not close"
_until 10 _recorded || fail "no undo record was written"
tm split-window -t t.0            # you put it back by hand
_until 10 _npanes 3 || fail "the manual split did not happen"
_o=$(tm run-shell "mux undo-pane" 2>&1 || true)
sleep 0.3
[ "$(tm list-panes -t t | wc -l)" = 3 ] \
	|| fail "undo added a pane to a window that was already whole. The
record alone does not mean something is missing -- the hole may have been
filled by hand since."

# --- with nothing closed, it says so --------------------------------------
build
_rc=0
_o=$(env XDG_RUNTIME_DIR="$T/run" TMUX= "$HERE/libexec/mux-undo-pane" 2>&1) \
	|| _rc=$?
[ "$_rc" != 0 ] || fail "with no record and no tmux, undo-pane must fail"

# --- an unknown option is an error ----------------------------------------
_rc=0
_o=$(env XDG_RUNTIME_DIR="$T/run" "$HERE/libexec/mux-undo-pane" --nope 2>&1) \
	|| _rc=$?
[ "$_rc" = 2 ] || fail "an unknown option must exit 2, got $_rc"
case $_o in
*"unknown option"*) ;;
*) fail "an unknown option did not say so: $_o" ;;
esac

pass
