#!/bin/sh
# test/mux-notice.t - the DURABLE NOTICE QUEUE: how a notice is keyed, queued,
# aged and handed back, plus the helper the client-detached hook calls.
#
# WRITTEN BECAUSE NOTHING ASSERTED ANY OF IT. mux-notice_lib's three functions
# and libexec/mux-notice-flush were between them 65 lines of shipped code with
# no behavioural test: mux-wire.t sources the lib, but only because
# `mux_env_apply` calls `mux_notice` as a side effect, so not one of its rules
# was held to anything. Every case below pins a rule the library's own comments
# record as having been got WRONG once.
#
# THE QUEUE IS NOT A CONVENIENCE. A notice exists because stderr is the wrong
# place: by the time the human detaches, the line mux printed is hours old and
# sits above a prompt they stopped looking at, and `mux sane` exists precisely
# because mux has paths that CLEAR the terminal and genuinely lose it. So the
# handback is the delivery that matters, and the rules about not losing a
# notice are the ones worth guarding.
set -eu
_name=mux-notice
. "$(dirname "$0")/harness_lib"

MUX_STATE=$T/state; export MUX_STATE
# shellcheck source=/dev/null
. "$HERE/lib/mux-paths_lib"
# shellcheck source=/dev/null
. "$HERE/lib/mux-notice_lib"

eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- the key ---------------------------------------------------------------
# ONLY `/` IS REPLACED, which is what keeps two ttys from colliding after
# sanitising: a key that folded every non-alphanumeric would map /dev/pts/1
# and /dev/pts.1 onto one queue and deliver one terminal's notices to another.
eq key "$(mux_notice_file /dev/pts/7)" "$T/state/notices/_dev_pts_7"
[ "$(mux_notice_file /dev/pts/1)" != "$(mux_notice_file /dev/pts.1)" ] \
  || fail "two distinct ttys collided after sanitising, so one terminal's
notices would be handed to another"

# WITH NO TTY THE KEY IS `unknown`, and getting that wrong is a measured bug
# rather than a hypothetical: `tty` PRINTS "not a tty" ON STDOUT and exits
# non-zero, so `$(tty || echo unknown)` concatenates BOTH and the key became
# `not_a_tty_unknown`. An agent pane is exactly a shell with no controlling
# terminal, so this is the common case here, not the edge.
eq key-no-tty "$(mux_notice_file </dev/null)" "$T/state/notices/unknown"

# --- queueing --------------------------------------------------------------
# STDERR NOW *AND* THE QUEUE, because the end may never come: a killed `mux
# go` still owes the human the reason at the moment it happened.
_err=$( (mux_notice probing 'the far side said nothing') 2>&1 >/dev/null \
        </dev/null )
eq notice-stderr "$_err" "mux: the far side said nothing"
_q=$(mux_notice_file </dev/null)
[ -s "$_q" ] || fail "mux_notice printed to stderr and queued NOTHING, so the
handback has nothing to deliver and the notice is lost on any path that clears
the terminal"
# TAB separated, because the text is prose and will contain spaces.
eq notice-fields "$(awk -F'\t' '{print NF}' "$_q")" "3"
eq notice-phase  "$(cut -f2 "$_q")" "probing"
eq notice-text   "$(cut -f3 "$_q")" "the far side said nothing"

# --- the handback ----------------------------------------------------------
# A FLUSH WITH NO TTY IS A NO-OP, not an error: the hook passes what it
# recorded at attach, and it may have recorded nothing.
mux_notice_flush || fail "a flush with no tty must be a quiet no-op: it runs
from a detach hook, which must never report an error as the human walks away"

# SILENT WHEN THERE IS NOTHING TO SAY, which is MOST detaches. This runs on
# every single one, so a detach that ends with mux clearing its throat would
# be worse than no mechanism at all.
TTY=$T/fake-tty
: >"$TTY"
rm -f "$T/state/notices/_fake-tty" 2>/dev/null || true
mkdir -p "$T/state/notices"
: >"$T/state/notices"/"$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9_.-' '_')"
mux_notice_flush "$TTY" || fail "an EMPTY queue must flush quietly"
eq flush-empty "$(cat "$TTY")" ""

# DELIVERS, WITH THE PHASE AND THE AGE. Each line carries its own age rather
# than being dropped for being old: a notice from a run that died is still
# delivered, and says when it happened instead of pretending to be current.
QF=$T/state/notices/$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9_.-' '_')
_now=$(date +%s)
{
  printf '%s\tprobing\tthe far side said nothing\n' "$(( _now - 5 ))"
  printf '%s\tattach\ttook the long way round\n'    "$(( _now - 600 ))"
  printf '%s\tresume\trebuilt four of six\n'        "$(( _now - 9000 ))"
  printf 'notanumber\twire\tthe clock said nothing\n'
} >"$QF"
mux_notice_flush "$TTY" || fail "a deliverable queue must flush successfully"
_got=$(cat "$TTY")
case $_got in *'mux noticed:'*) ;;
  *) fail "the handback printed no header, so two unrelated messages land on
adjacent lines and read as one: [$_got]" ;;
esac
# THE THREE AGE BANDS, each its own assertion: one "it mentioned an age" check
# passes on a single working band and says nothing about the other two.
case $_got in *'probing, 5s ago: the far side said nothing'*) ;;
  *) fail "under 90s must read in SECONDS: [$_got]" ;;
esac
case $_got in *'attach, 10m ago: took the long way round'*) ;;
  *) fail "under 5400s must read in MINUTES: [$_got]" ;;
esac
case $_got in *'resume, 2h ago: rebuilt four of six'*) ;;
  *) fail "past 5400s must read in HOURS: [$_got]" ;;
esac
# A TIMESTAMP THAT IS NOT A NUMBER COSTS THE AGE, NEVER THE NOTICE. The
# arithmetic would fail on it, and the text is the part the human needs.
case $_got in *'wire: the clock said nothing'*) ;;
  *) fail "a non-numeric timestamp dropped the whole notice, when the only
thing it should cost is the age: [$_got]" ;;
esac

# DELIVERED ONCE: the queue is removed, so the next detach on that terminal is
# silent rather than repeating itself for ever.
[ ! -e "$QF" ] || fail "the queue survived a SUCCESSFUL delivery, so every
later detach on this terminal repeats the same notices"

# --- ... AND A FAILED DELIVERY KEEPS IT ------------------------------------
# THE LOAD-BEARING RULE, and the one the first version got backwards: it
# removed the queue unconditionally and lost the notice, found by an
# end-to-end run where the tty had already been released. A notice that could
# not be delivered is exactly the one worth keeping.
#
# A DIRECTORY IS THE CHEAPEST UNWRITABLE TARGET, and it models the real cause
# (`cannot create /dev/pts/21: Permission denied` on a released tty) closely
# enough: the redirect cannot open it either way.
DEADTTY=$T/released
mkdir -p "$DEADTTY"
DQF=$T/state/notices/$(printf '%s' "$DEADTTY" | tr -c 'A-Za-z0-9_.-' '_')
printf '%s\tprobing\tnobody heard this\n' "$(date +%s)" >"$DQF"
_rc=0
mux_notice_flush "$DEADTTY" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] || fail "a flush that could not write anywhere reported
SUCCESS, so a caller cannot tell a delivered notice from a lost one"
[ -s "$DQF" ] || fail "delivery failed and the queue was removed anyway, which
loses precisely the notice worth keeping. The next detach on that terminal
should carry it, with its age."

# --- the helper the hook calls ---------------------------------------------
# NEVER FAILS THE HOOK, on either path. A notice is a courtesy, and tmux must
# not report an error as the human walks away.
FLUSH=$HERE/libexec/mux-notice-flush
_rc=0
env MUX_STATE="$T/state" "$FLUSH" >"$T/h1.out" 2>"$T/h1.err" </dev/null \
  || _rc=$?
eq helper-no-arg-rc "$_rc" "0"
eq helper-no-arg-out "$(cat "$T/h1.out")" ""
eq helper-no-arg-err "$(cat "$T/h1.err")" ""

# ... INCLUDING when the library's flush fails: the queue above is still
# undeliverable, so this exercises the `|| true` rather than a quiet path.
_rc=0
env MUX_STATE="$T/state" "$FLUSH" "$DEADTTY" >"$T/h2.out" 2>"$T/h2.err" \
  </dev/null || _rc=$?
eq helper-failed-rc "$_rc" "0"
eq helper-failed-err "$(cat "$T/h2.err")" ""
[ -s "$DQF" ] || fail "the helper lost the queue on a failed delivery"

# ... and it DELIVERS when it can, which is the half that proves the helper is
# wired to the library at all rather than merely exiting 0 on everything.
printf '%s\tattach\tthe helper delivered this\n' "$(date +%s)" >"$QF"
: >"$TTY"
env MUX_STATE="$T/state" "$FLUSH" "$TTY" >/dev/null 2>&1 </dev/null \
  || fail "the helper failed on a deliverable queue"
case $(cat "$TTY") in *'the helper delivered this'*) ;;
  *) fail "the helper exited 0 and delivered nothing, which is what an
unwired helper also looks like" ;;
esac

pass
