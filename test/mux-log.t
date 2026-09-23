#!/bin/sh
# test/mux-log.t - mux's one log, and the reader that makes it findable.
#
# WHY THE LOG EXISTS, because it shapes every assertion here: `mux latch` held a
# session across an hour-long outage, a MITM and a recovery, and left NOTHING
# behind. Every transition went to stderr; the whole state machine was shell
# variables that died with the process. That recovery happened to work. Had it
# not, the only evidence would have been scrollback in a terminal latch had just
# finished un-wedging.
#
# So the properties worth pinning are not "it writes a line". They are:
#
#   1. A LOG WRITE MUST NEVER BREAK ITS CALLER. latch must not die because a
#      disk filled or a path went read-only. Best-effort is the contract, and
#      it is the one that a refactor is most likely to "tidy" into a hard fail.
#   2. THE READER MUST DISTINGUISH ITS SILENCES. "logging is off", "nothing has
#      happened yet", "the file is empty" and "no entries for that subsystem"
#      are four different answers, and showing all four as no output would make
#      the log useless exactly when it is consulted -- after an incident, when
#      you cannot tell "nothing went wrong" from "nothing was recorded".
#   3. IT IS CAPPED. An unbounded always-on file is its own bug.
set -eu
_name=mux-log
. "$(dirname "$0")/lib.sh"

LIB=$HERE/libexec/mux-log.sh
[ -r "$LIB" ] || fail "libexec/mux-log.sh is missing"

L=$T/state/mux.log
lg() {   # <subsys> <msg...> -- through the real lib, never by hand
	( . "$LIB"; MUX_STATE="$T/state" mux_log "$@" )
}
rd() {   # [args...] -> reader stdout+stderr
	env MUX_STATE="$T/state" "$HERE/bin/mux" log "$@" 2>&1
}
rc() {   # [args...] -> reader exit code
	_r=0
	env MUX_STATE="$T/state" "$HERE/bin/mux" log "$@" >/dev/null 2>&1 \
		|| _r=$?
	echo "$_r"
}
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in: $1" ;; esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in: $1" ;; esac; }

# --- the reader tells its four silences apart -----------------------------
# Asserted BEFORE anything is written, because "no log yet" is the state a fresh
# box is in and the one most likely to be mistaken for a fault.
_o=$(rd || true)
has "$_o" "no log yet" "a never-written log must say so, not print nothing"
has "$_o" "$L" "the reader must name the path it looked at"
[ "$(rc)" = 1 ] || fail "a missing log must exit non-zero, so a script notices"

_o=$(env MUX_LOG=none MUX_STATE="$T/state" "$HERE/bin/mux" log 2>&1 || true)
has "$_o" "OFF" "MUX_LOG=none must be reported as OFF, not as an empty log"
# ... and OFF must CREATE nothing. A disabled log that still makes a directory
# has not really been disabled. Checked against a path NOTHING has touched:
# lib.sh pins MUX_STATE and mkdir -p's it, so $T/state exists already and would
# have made this assertion pass for the wrong reason.
( . "$LIB"; MUX_LOG=none MUX_STATE="$T/untouched" mux_log latch 'x' )
[ ! -e "$T/untouched" ] || fail "MUX_LOG=none created $T/untouched"

# --- MUX_LOG is three-valued, and the middle value is the interesting one --
# unset / none / a path. Collapsing "unset" with "off" is a mistake this
# codebase paid for once already (the _ask seam in mux-latch returned 2 for both
# "no hook configured" and "the hook cannot tell", and the caller waited
# forever). Asserted through the lib's own resolver, not by reading the source.
_p() { ( . "$LIB"; MUX_STATE="$T/state" mux_log_path ); }
[ "$(_p)" = "$L" ] || fail "unset MUX_LOG must give the default path, got $(_p)"
[ "$(MUX_LOG=none _p)" = "" ] || fail "MUX_LOG=none must resolve to no path"
[ "$(MUX_LOG=$T/elsewhere.log _p)" = "$T/elsewhere.log" ] \
	|| fail "an explicit MUX_LOG path must win"

# --- the format: timestamp, subsystem[pid], message ----------------------
lg latch 'attaching -- manifestor via ssh'
[ -f "$L" ] || fail "mux_log wrote nothing (and created no log)"
_line=$(cat "$L")
case $_line in
20??-??-??T??:??:??Z' latch['*'] attaching -- manifestor via ssh') ;;
*) fail "the line is not <iso-ts> <subsys>[<pid>] <msg>:
  $_line" ;;
esac
# The PID is there so two concurrent latches (to different hosts) can be told
# apart in one file. Without it an interleaved log reads as one confused run.
#
# Proved with a genuinely SEPARATE process, which is the only way to prove it.
# `( . "$LIB"; mux_log ... )` is a subshell, and a POSIX subshell inherits $$
# from its parent -- so every entry lg() writes carries the TEST's pid, and an
# assertion comparing against $$ would pass whether the field tracked the writer
# or were hardcoded. A child `sh -c` has a pid of its own.
_kid=$(sh -c '. "$1"; MUX_STATE="$2" mux_log latch "from a child process"; \
	echo $$' -- "$LIB" "$T/state")
_got=$(grep 'from a child process' "$L" | sed 's/.*latch\[\([0-9]*\)\].*/\1/')
[ "$_got" = "$_kid" ] || fail "the pid field does not track the WRITER:
  the child's pid was [$_kid], the log recorded [$_got]"
[ "$_got" != "$$" ] || fail "the child logged the test's pid, so the field is
not the writer's -- two concurrent latches would be indistinguishable"

# --- an empty message is not an entry ------------------------------------
# A bare subsystem with nothing to say would append a line carrying only a
# timestamp, which is noise that looks like a truncated record.
_before=$(wc -l <"$L")
lg latch
lg latch ''
[ "$(wc -l <"$L")" = "$_before" ] \
	|| fail "an empty message was logged as an entry"

# --- A WRITE MUST NEVER FAIL ITS CALLER ---------------------------------
# The contract that matters most. latch is holding a live session; it must not
# die because the log cannot be written. Each case returns 0 or the test fails,
# and `set -e` in this file means a non-zero return takes the run down.
#
# THREE CASES BECAUSE THERE ARE TWO GUARDS, and which case reaches which is not
# obvious -- mutation testing is what showed it. The first two have a dirname
# that does not exist, so they fail at the `mkdir -p` refusal and never attempt
# the write at all. Only the third has an existing-but-unwritable directory,
# which skips mkdir and reaches the append. Both refusals are load-bearing and
# each is mutated separately in test/mutants; a comment claiming the first case
# covers the write would have been wrong.
( . "$LIB"; MUX_LOG=/proc/definitely/not/writable/x mux_log latch 'x' ) \
	|| fail "an unwritable PATH made mux_log fail (the mkdir guard).
Best-effort is the contract: a full disk must not kill the latch
that is holding your session."
mkdir -p "$T/ro"; chmod 500 "$T/ro"
( . "$LIB"; MUX_LOG=$T/ro/sub/x.log mux_log latch 'x' ) \
	|| fail "an uncreatable DIRECTORY made mux_log fail (the mkdir guard)"
( . "$LIB"; MUX_LOG=$T/ro/x.log mux_log latch 'x' ) \
	|| fail "an unwritable DIRECTORY made mux_log fail (the write guard)"
chmod 700 "$T/ro"

# --- the subsystem filter matches the FIELD, not the line ---------------
# A doctor entry whose TEXT mentions latch is not a latch entry. Grepping the
# whole line would return it, and the failure is quiet: you read someone else's
# events as your subsystem's and reason from them.
lg doctor 'repaired vigilance (%4): working -> idle'
lg doctor 'a message that merely mentions latch in its text'
_o=$(rd latch || true)
has "$_o" "attaching -- manifestor" "the latch entry was filtered out"
no_has "$_o" "merely mentions latch" "the filter matched the MESSAGE, not the
subsystem field. A doctor line mentioning latch must not read as a latch entry."
_o=$(rd doctor || true)
has "$_o" "repaired vigilance" "the doctor entries were filtered out"
no_has "$_o" "attaching -- manifestor" "a latch entry leaked into doctor"

# A filter matching nothing is REPORTED, not shown as an empty log: the same
# rule test/mutate applies to itself, where a filter matching no mutant is a
# failure rather than a pass.
_o=$(rd no-such-subsystem || true)
has "$_o" "no 'no-such-subsystem' entries" "an empty filter result said nothing"
[ "$(rc no-such-subsystem)" = 1 ] || fail "an empty filter result must exit 1"

# --- -n bounds the output, and is validated -----------------------------
lg latch 'one'; lg latch 'two'; lg latch 'three'
[ "$(rd -n 2 latch | wc -l)" = 2 ] || fail "-n 2 did not return 2 lines"
[ "$(rd -n2 latch | wc -l)" = 2 ] || fail "-n2 (attached form) did not work"
# The LAST lines, not the first: a log is read from the end, where the incident
# you are chasing is.
has "$(rd -n 1 latch)" "three" "-n 1 returned the OLDEST entry, not the newest"
[ "$(rc -n notanumber)" = 2 ] || fail "-n with a non-number must exit 2"
[ "$(rc --bogus)" = 2 ] || fail "an unknown option must exit 2"

# --- CAPPED, not unbounded ----------------------------------------------
# Always-on plus unbounded is a bug waiting on a long uptime. The cap is safe
# only BECAUSE the log records mutations and failures rather than activity; if
# truncation ever fires in real use, something is logging routine events.
: >"$L"
_i=0
while [ "$_i" -lt 40 ]; do
	( . "$LIB"; MUX_STATE="$T/state" MUX_LOG_MAX=400 \
		mux_log latch "entry number $_i padded out to take up room" )
	_i=$((_i + 1))
done
_sz=$(wc -c <"$L")
[ "$_sz" -le 1200 ] || fail "the log grew to $_sz bytes against MUX_LOG_MAX=400,
so the cap is not firing and an always-on log is unbounded"
# Truncation must leave the file USABLE rather than half a line: the newest
# entry has to survive, or the cap destroys exactly what you came to read.
has "$(cat "$L")" "entry number 39" "the newest entry did not survive the cap"

pass
