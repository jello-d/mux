#!/bin/sh
# mux-log.sh - ONE log for the whole package. Sourced (functions only); source
# it, do not run it.
#
# WHY IT EXISTS. `mux latch` held a session across an hour-long outage, a MITM
# and a recovery, and left NOTHING behind: every transition went to stderr and
# its whole state machine lived in shell variables that died with the process.
# The recovery was fine. Had it NOT been, the only evidence would have been
# scrollback in a terminal that latch had just finished un-wedging, which is the
# worst imaginable place to keep a post-mortem.
#
# ALWAYS ON, and that is the whole point. A log you have to switch on before the
# incident cannot help with an incident you cannot reproduce -- and a network
# outage is exactly that. `MUX_EMIT_LOG` is opt-in because it fires on every
# tool call; this one is always on because it is rare by construction:
#
#   LOG WHAT MUX CHANGED, AND WHAT MUX COULD NOT DO.
#
# Mutations and failures, never routine activity. That rule is what keeps the
# volume near zero, and it is also what makes the file answer the question you
# actually have afterwards. A status tick, a render, an `agent-emit` on every
# PostToolUse: all OUT. A latch transition, a doctor repairing a record, a sweep
# deleting files: all IN. When adding a call, ask which of the two it is; if it
# is neither, it does not belong here.
#
# WHERE. $MUX_STATE, because a log cannot be REBUILT -- the test mux-paths.sh
# makes the whole design. The XDG spec independently agrees, naming logs as
# $XDG_STATE_HOME content. Derived with the plain one-line default rather than
# through mux_state_path: that function's value is its ADOPTION rule (migrating
# a file that used to live in the cache), and a log that never lived anywhere
# else has nothing to adopt. So this lib stays dependency-free and any helper
# can source it alone.
#
# MUX_LOG is three-valued on purpose, because "unset" and "off" are different
# instructions and collapsing them is a mistake this codebase has already paid
# for once (see the _ask seam in mux-latch):
#
#   unset   the default path, $MUX_STATE/mux.log
#   none    disabled; nothing is written and nothing is created
#   <path>  that file
#
# BEST EFFORT, DELIBERATELY. A failed log write must never break the thing being
# logged -- latch must not die because a disk filled. That does conflict with
# "fail loud, never silent", so the resolution is at the READER: `mux log`
# reports an unwritable or missing log, so the breakage surfaces at the moment
# you go looking for it rather than never.

# mux_log_path -> the log file, or empty when logging is off.
mux_log_path() {
	case ${MUX_LOG:-} in
	none) return 0 ;;
	?*)   printf '%s' "$MUX_LOG"; return 0 ;;
	esac
	printf '%s/mux.log' \
		"${MUX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/mux}"
}

# mux_log SUBSYS MESSAGE... -> append one line. Always returns 0.
#
# CAPPED, NOT ROTATED. The same argument agent-state-emit's breadcrumb makes: an
# unbounded file is its own bug. Truncation is safe here only BECAUSE of the
# rule above -- at mutations-and-failures volume the default cap holds years of
# incidents, so in practice it never fires. If it starts firing, something is
# logging routine activity and that is the bug to fix, not the cap to raise.
#
# One short line through a single >> is atomic under O_APPEND on Linux, which is
# what makes two concurrent latches safe to interleave without locking.
mux_log() {   # <subsystem> <message...>
	_ml_f=$(mux_log_path)
	[ -n "$_ml_f" ] || return 0
	_ml_s=$1; shift
	[ -n "${1:-}" ] || return 0

	_ml_d=$(dirname "$_ml_f")
	[ -d "$_ml_d" ] || mkdir -p "$_ml_d" 2>/dev/null || return 0

	_ml_max=${MUX_LOG_MAX:-262144}
	if [ -f "$_ml_f" ] \
	   && [ "$(wc -c 2>/dev/null <"$_ml_f" || echo 0)" -gt "$_ml_max" ]
	then
		: 2>/dev/null >"$_ml_f" || return 0
	fi

	printf '%s %s[%s] %s\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_ml_s" "$$" "$*" \
		2>/dev/null >>"$_ml_f" || return 0
	return 0
}
