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
. "$(dirname "$0")/harness_lib"

command -v tmux >/dev/null 2>&1 || {
	printf 'skip %s (no tmux)\n' "$_name"; exit 0; }

SOCK=$(tmux_fresh_socket muxundo)
XDG_RUNTIME_DIR=$T/run; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
PATH=$HERE/bin:$PATH; export PATH

tm() { tmux -L "$SOCK" "$@"; }
cleanup() { tmux_drop_socket "$SOCK"; }

# WHERE IT DIED, because this file has now gone NO VERDICT three times under a
# loaded full-suite run and never once in isolation -- twice during a mutation
# sweep, once during a plain `test/run`. It drives a REAL tmux, so it is the
# one file exposed to contention, and under `set -e` a tmux command that fails
# takes the whole file down with nothing printed at all: no ok, no FAIL, just
# a gap the runner has to report second-hand.
#
# `stage` costs one variable assignment and turns the next occurrence from
# "something happened somewhere in 250 lines" into a named step. Cheaper than
# another afternoon of not reproducing it, and it does not attempt a FIX for
# a cause nobody has seen yet.
STAGE=startup
stage() { STAGE=$*; }
_bail() {
	_rc=$?
	cleanup
	[ "$_rc" = 0 ] && return 0
	[ -n "${MUX_T_SAID:-}" ] && return 0
	printf 'FAIL %s: died at stage [%s] with status %s and said nothing.\n' \
		"$_name" "$STAGE" "$_rc"
	printf '  This is the contention flake; capture the state above.\n'
}
trap '_bail' EXIT
trap 'cleanup' INT TERM

# A SERVER ON A NAME NOBODY HAS KILLED. build() used to `cleanup` and then
# immediately create on the SAME socket, which races tmux's teardown -- see
# tmux_fresh_socket in harness_lib. That is what made this file flake under the
# full
# suite and never in isolation. The old server is killed and NOT waited for,
# because there is nothing reliable to wait on.
rotate() {
	cleanup
	SOCK=$(tmux_fresh_socket muxundo)
	# AND THE RECORDS GO WITH THE SERVER. This is the whole undo-pane flake,
	# finally caught: a record is keyed by WINDOW ID, every fresh tmux server
	# calls its first window `@0`, and $XDG_RUNTIME_DIR is shared across
	# cycles -- so the previous cycle's record sits at the path this cycle
	# will write. `_recorded` only asks whether the DIRECTORY is non-empty,
	# so it returned true instantly from the stale file and the undo then
	# raced the new recorder. When it lost, the slot-0 cycle restored the
	# SLOT-1 record: cwd /etc, slot 1, which is exactly the observed
	# `before [30:/tmp 9:/etc 19:/usr] / after [30:/etc 9:/etc 19:/usr]`.
	#
	# Measured at roughly 1 in 6 isolated runs before this line existed.
	# The product half of the same root cause is fixed separately, and is
	# asserted below: a record now names its server and is refused elsewhere.
	rm -rf "$T/run/mux-undo"
}

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
	stage "building the window (a fresh socket each time)"
	rotate
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
	# THE LAST TRACKER, NOT THE FIRST. The three snapshots are three
	# SEPARATE hook commands appended to window-layout-changed -- @mux-ul,
	# then @mux-up, then @mux-uc -- so waiting on @mux-ul proves only that
	# the first has landed. Under load the gap widens, the pane dies inside
	# it, and the record is written from a cwd snapshot that does not list
	# the pane: the restore then puts it back in its NEIGHBOUR's directory.
	# That is what a full-suite run actually caught, once in twelve, with
	# every height correct and slot 0 at /etc instead of /tmp.
	_until 5 test -n "$(tm show-options -wqv -t t @mux-uc)" \
		|| fail "the cwd tracker never recorded anything"
}

# --- THE RECORD IS WRITTEN UNQUOTED -- asserted before anything is restored
# tmux hands `pane_start_command` back QUOTED for display (wrapped, with inner
# quotes and $ escaped). Replaying that verbatim does not fail loudly: the pane
# is created and runs the wrong thing, which is exactly how it survived a first
# live check.
#
# THIS COMES FIRST, AND ON THE FILE RATHER THAN ON A PANE, because it is the
# only DETERMINISTIC observable of the unquote. A pane replaying a mangled
# command is created and dies at once, so every assertion downstream of it is
# a race between the restore and the death, and which one fires is decided by
# machine load. That non-determinism is what made this file's own mutation
# record report the wrong assertion under a busy run.
stage "the record is written unquoted"
build
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "unquote: the pane did not close"
_until 10 _recorded || fail "unquote: no undo record was written"
_cr=$(sed -n 's/^command	//p' "$T/run/mux-undo/$(ls -A "$T/run/mux-undo" \
	| head -1)")
# `[\\]`, a bracket expression, rather than a quoted backslash: `'\\'` inside
# single quotes is TWO characters and shellcheck rightly calls it ambiguous
# (SC1003) -- the same trap these notes record costing a doubled spinner.
# A BACKSLASH is the discriminator, not a quote. The real command contains
# double quotes of its own (`exec "${SHELL:-/bin/sh}"`); what the display form
# adds is ESCAPES -- it wraps the whole thing and backslash-escapes the inner
# `"` and `$`. Checking for a quote fails on correct code, which it did here.
case $_cr in
*[\\]*) fail "the recorded command is still tmux's DISPLAY form, quoted
and escaped: [$_cr]. Replaying that does not fail loudly -- the pane comes
back running the wrong thing, which is how it survived a first live check." ;;
esac
case $_cr in
*MARK_A*) ;;
*) fail "the recorded command lost the command itself: [$_cr]" ;;
esac

# --- the layout comes back exactly, wherever the hole was -----------------
stage "the layout comes back exactly, wherever the hole was"
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
stage "the SURVIVING panes are never touched"
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
stage "what it was RUNNING comes back"
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
stage "the directory is remembered"
_until 10 _cwds_ready || true
case "$(state)" in
*":/etc "*) ;;
*) fail "the restored pane did not come back in its old directory: $(state)" ;;
esac

# --- twice is once --------------------------------------------------------
stage "twice is once"
# The record is consumed, so a second undo cannot bolt on a pane nobody lost.
_o=$(tm run-shell "mux undo-pane" 2>&1 || true)
[ "$(tm list-panes -t t | wc -l)" = 3 ] \
	|| fail "a second undo added a pane nobody closed"

# --- ... and so is filling the hole YOURSELF ------------------------------
stage "... and so is filling the hole YOURSELF"
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

# --- THE PANE'S OWN OPTIONS COME BACK WITH IT -----------------------------
stage "THE PANE'S OWN OPTIONS COME BACK WITH IT"
# Losing @mux-bottom is not cosmetic and not recoverable by looking: `mux pin`
# skips an unmarked pane AND the width balance refuses (with no marker it
# cannot tell the bottom pane from the row above), so one dropped option
# freezes that window's geometry silently and for good. Found on a live
# session whose panes had drifted to 81|79 with prefix-R doing nothing.
#
# Asserted on the OPTION, not on the resulting size: the pane comes back at
# the right size either way, because the saved LAYOUT sets it. The damage only
# shows later, the next time something tries to hold that size.
build
_bot=$(tm list-panes -t t -F '#{pane_id}' | tail -1)
tm set-option -p -t "$_bot" @mux-bottom 5-10
tm set-option -p -t "$_bot" @mux-agent 1
# A LAYOUT CHANGE IS WHAT LATCHES THE TRACKER. Setting a pane option is not
# one, so the value is picked up on the next geometry event -- which in mux's
# own build path is the next split, and in life is any resize. Forced here so
# the test asserts the restore rather than the hook's timing.
tm resize-pane -t t.0 -y 29
_until 5 sh -c 'tmux -L '"$SOCK"' show-options -wqv -t t @mux-uo \
	| grep -q 5-10' || fail "the option tracker never saw @mux-bottom"

tm send-keys -t "$_bot" 'exit' Enter
_until 10 _npanes 2 || fail "the bottom pane did not close"
_until 10 _recorded || fail "no undo record was written"
tm run-shell "mux undo-pane" >/dev/null 2>&1 || true
_until 10 _npanes 3 || fail "undo restored no pane"

_new=$(tm list-panes -t t -F '#{pane_id}' | tail -1)
[ "$(tm show-options -pqv -t "$_new" @mux-bottom)" = 5-10 ] \
	|| fail "@mux-bottom did not come back on the restored pane, so
mux pin will skip it and the width balance will refuse -- that window's
geometry is frozen and nothing says so"
[ "$(tm show-options -pqv -t "$_new" @mux-agent)" = 1 ] \
	|| fail "@mux-agent did not come back, so 'mux save' would read the
running command and record an exited agent as a plain shell"

# --- with nothing closed, it says so --------------------------------------
stage "with nothing closed, it says so"
build
_rc=0
_o=$(env XDG_RUNTIME_DIR="$T/run" TMUX= "$HERE/libexec/mux-undo-pane" 2>&1) \
	|| _rc=$?
[ "$_rc" != 0 ] || fail "with no record and no tmux, undo-pane must fail"

# --- AN UNKNOWN DIRECTORY IS SAID, NOT INHERITED -------------------------
# Without `-c`, split-window uses the ANCHOR pane's directory -- so a cwd the
# record does not have does not fail, it puts the pane back beside its
# neighbour and says nothing. Asserted on the MESSAGE, because the placement
# itself is indistinguishable from a correct restore of a pane that genuinely
# lived there.
build
stage "an unknown directory is said, not inherited"
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "nocwd: the pane did not close"
_until 10 _recorded || fail "nocwd: no undo record was written"
_rec=$T/run/mux-undo/$(ls -A "$T/run/mux-undo" | head -1)
grep -v '^cwd	' "$_rec" >"$_rec.x" && mv -f "$_rec.x" "$_rec"
_sp=$(tm display-message -p '#{socket_path}')
_o=$(env TMUX="$_sp,0,0" "$HERE/libexec/mux-undo-pane" 2>&1 || true)
case $_o in
*"directory was not recorded"*) ;;
*) fail "a record with no cwd restored SILENTLY into the neighbour's
directory: [$_o]" ;;
esac
_until 10 _npanes 3 || fail "nocwd: the pane should still come back -- the
directory is the only thing lost, and losing the pane as well would be worse"

# --- A RECORD BELONGS TO ONE SERVER -------------------------------------
# THE ROOT CAUSE OF THE FLAKE THIS FILE SPENT FIVE SIGHTINGS ON, and a live
# product bug in its own right. A record is keyed by WINDOW ID, and a window id
# is NOT unique across server lifetimes: every fresh tmux server calls its first
# window `@0` (measured). So a record outlives the server that wrote it, and the
# next server's first window inherits it.
#
# VERIFIED BY HAND BEFORE THIS WAS WRITTEN: a brand new server on a different
# socket, with one pane and nothing ever lost in it, restored a pane from a dead
# server's window -- with that window's command, cwd and LAYOUT, which is
# applied positionally and so resizes the survivors too. Plausible, wrong,
# silent: this codebase's recurring failure shape.
#
# The record's server is rewritten rather than a second server being driven,
# because what is under test is the CHECK, and a fixture that needs two live
# servers to say one thing is a fixture that can fail for other reasons.
build
stage "a record belongs to one server"
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "otherserver: the pane did not close"
_until 10 _recorded || fail "otherserver: no undo record was written"
_rec=$T/run/mux-undo/$(ls -A "$T/run/mux-undo" | head -1)
sed 's/^server	.*/server	999999/' "$_rec" >"$_rec.x" && mv -f "$_rec.x" "$_rec"
_sp=$(tm display-message -p '#{socket_path}')
_rc=0
_o=$(env TMUX="$_sp,0,0" "$HERE/libexec/mux-undo-pane" 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "a record from another server was accepted"
case $_o in
*"server that is gone"*) ;;
*) fail "the refusal did not say the record belongs to another server, so a
phantom restore is indistinguishable from a real one: [$_o]" ;;
esac
_npanes 2 || fail "a record from another server RESTORED A PANE: $(state)"
# AND IT IS DISCARDED, or every press repeats the refusal for a record that can
# never become valid.
[ -n "$(ls -A "$T/run/mux-undo" 2>/dev/null)" ] \
	&& fail "the foreign record was refused and KEPT, so the window is stuck
answering this instead of the ordinary 'nothing to undo'"

# A RECORD THAT CANNOT SAY is refused too, on the same rule the latch hooks
# follow: an edge nobody can check must not report success. This is what a
# record written by a mux older than the field looks like.
build
stage "a record with no server field"
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "noserver: the pane did not close"
_until 10 _recorded || fail "noserver: no undo record was written"
_rec=$T/run/mux-undo/$(ls -A "$T/run/mux-undo" | head -1)
grep -v '^server	' "$_rec" >"$_rec.x" && mv -f "$_rec.x" "$_rec"
_sp=$(tm display-message -p '#{socket_path}')
_rc=0
_o=$(env TMUX="$_sp,0,0" "$HERE/libexec/mux-undo-pane" 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "a record that cannot name its server was accepted"
_npanes 2 || fail "an unattributable record RESTORED A PANE: $(state)"
# A DIFFERENT SENTENCE FROM THE FOREIGN CASE, because they are one condition
# for the code and different news for a human: "this is someone else's" and
# "this cannot be attributed at all" want different reactions, and sharing a
# message would make the second a lie about the first.
case $_o in
*"does not say which server"*) ;;
*) fail "an unattributable record was refused with the foreign-server
sentence, which is not what happened: [$_o]" ;;
esac

# --- A PARTIAL RECORD IS REFUSED, LOUDLY ---------------------------------
# The other half of writing the record atomically, and the half that can be
# asserted deterministically. `> file` creates and truncates before any bytes
# land, and the writer forks four command substitutions in between, so a
# reader could see the file empty or half-written -- suspected cause of this
# file's own flake, which only ever appeared under a loaded suite run.
#
# THE FAILURE IS SILENT WITHOUT THIS, which is why it is worth a case: undo
# runs from a key binding, tmux swallows its stderr, and a partial record just
# means the pane does not come back. Asserted on the MESSAGE and on the pane
# count, because "it refused" and "it refused without doing damage" are two
# different promises.
build
stage "a partial record is refused"
_before=$(state)
tm send-keys -t t.1 'exit' Enter
_until 10 _npanes 2 || fail "partial: the pane did not close"
_until 10 _recorded || fail "partial: no undo record was written"
_rec=$T/run/mux-undo/$(ls -A "$T/run/mux-undo" | head -1)
printf 'slot\t1\n' >"$_rec"          # everything after `slot` is missing
# DIRECTLY, with $TMUX pointed at this server, because the MESSAGE is the
# observable here and through run-shell tmux reports only "returned 1" -- the
# stderr it swallows is the whole reason a partial record fails silently in
# real life. Same reason mux-even.t drives its refusal case this way.
_sp=$(tm display-message -p '#{socket_path}')
_rc=0
_o=$(env TMUX="$_sp,0,0" "$HERE/libexec/mux-undo-pane" 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "a half-written record was accepted (exit 0): [$_o]"
case $_o in
*unusable*) ;;
*) fail "a half-written record was not refused by name: [$_o]" ;;
esac
[ "$(tm list-panes -t t 2>/dev/null | wc -l)" = 2 ] \
	|| fail "a half-written record still changed the window: it must refuse
before touching anything, or a truncated file rearranges a live layout"

# --- an unknown option is an error ----------------------------------------
stage "an unknown option is an error"
_rc=0
_o=$(env XDG_RUNTIME_DIR="$T/run" "$HERE/libexec/mux-undo-pane" --nope 2>&1) \
	|| _rc=$?
[ "$_rc" = 2 ] || fail "an unknown option must exit 2, got $_rc"
case $_o in
*"unknown option"*) ;;
*) fail "an unknown option did not say so: $_o" ;;
esac

pass
