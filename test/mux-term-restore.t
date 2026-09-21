#!/bin/sh
# test/mux-term-restore.t - putting the terminal back after tmux died with ssh.
#
# THE BUG IT REPAIRS. tmux switches the terminal into a different operating mode
# on the way in and switches it back on the way out. When ssh dies mid-session
# the way out never happens: cursor hidden, mouse reporting still on (so moving
# the mouse types control characters at your shell), bracketed paste still on,
# alternate screen still up.
#
# `stty sane` is the reflex and it only half works, for a reason worth stating
# once: there are TWO pieces of state. The tty line discipline lives in the
# KERNEL and stty owns it. The alternate screen, cursor visibility, mouse
# reporting and bracketed paste live in the terminal EMULATOR, set by escape
# sequences, and the kernel has never heard of them. Only sending the matching
# sequences can put those back.
#
# WHAT IS ASSERTED HERE is the byte stream, because that is what this program
# controls. The sequences themselves were MEASURED rather than invented: a tmux
# session was attached and detached through a pty and its teardown captured, so
# these are tmux's own resets. Whether a given emulator honours them is the
# emulator's contract, not this program's, and no test here can stand in for it.
set -eu
_name=mux-term-restore
. "$(dirname "$0")/lib.sh"

HOOK=$HERE/share/latch/term-restore
[ -x "$HOOK" ] || fail "share/latch/term-restore is missing or not executable"

# --- WITH NO TERMINAL IT MUST BE COMPLETELY SILENT ----------------------
# The dangerous failure, and the reason this assertion comes first. Escape
# sequences written into a pipe corrupt whatever is reading it, and latch runs
# this on EVERY transport return -- including in scripts and in this suite.
_out=$T/quiet
_rc=0
"$HOOK" >"$_out" 2>&1 </dev/null || _rc=$?
[ "$_rc" = 0 ] || fail "term-restore must always exit 0 (it is a repair, not a
question), got $_rc"
[ ! -s "$_out" ] || fail "term-restore wrote $(wc -c <"$_out") bytes with no
terminal attached. Anything on stdout here corrupts a caller's pipe:
$(cat -v "$_out")"

# --- WITH A PTY IT EMITS THE RESETS -------------------------------------
if ! command -v script >/dev/null 2>&1; then
	printf 'skip %s (no script(1), cannot supply a pty)\n' "$_name"
	exit 0
fi
_raw=$T/raw
script -qc "sh $HOOK" "$_raw" >/dev/null 2>&1 || true
[ -s "$_raw" ] || fail "nothing was captured from the pty run"
_seen=$(cat -v "$_raw")

# Each of these was observed in tmux's own teardown. A terminal left with any
# one of them still set is a terminal that stays broken in a specific way, so
# they are named individually rather than checked as one blob.
for _m in \
	'1049l:the alternate screen, so your own scrollback comes back' \
	'25h:the cursor, which is invisible until this is sent' \
	'1000l:mouse reporting (X10) -- the control characters' \
	'1002l:mouse reporting (button-event)' \
	'1003l:mouse reporting (any-event)' \
	'1006l:mouse reporting (SGR), the protocol tmux actually uses' \
	'2004l:bracketed paste, or every paste arrives wrapped in ESC[200~' \
	'1004l:focus reporting, which emits ESC[I and ESC[O on focus change'
do
	_code=${_m%%:*}; _why=${_m#*:}
	case $_seen in
	*"^[[?$_code"*) ;;
	*) fail "term-restore never reset ?$_code -- $_why
What it emitted:
$_seen" ;;
	esac
done

# The kernel half is not optional either.
grep -q 'stty sane' "$HOOK" \
	|| fail "term-restore no longer runs stty sane, so the tty line
discipline (echo, canonical mode, signal characters) is left as tmux set it"

# --- AND IT MUST NOT CLEAR THE SCREEN -----------------------------------
# THE DELIBERATE OMISSION. tmux clears (ESC[H ESC[J) just before leaving the
# alternate screen, which is safe for tmux because it knows it is on that
# screen. This program does NOT know: ssh may have died before tmux ever
# switched, or something may have tidied up already. Replaying the clear would
# then wipe the user's real screen while claiming to repair it -- destroying
# work in the name of fixing it. It is also redundant, since leaving the
# alternate screen discards its contents anyway.
case $_seen in
*'^[[H^[[J'*|*'^[[2J'*) fail "term-restore clears the screen. If the terminal
is NOT on the alternate screen this wipes real content, and leaving the
alternate screen already discards its buffer, so the clear can only ever do
harm here. Emitted:
$_seen" ;;
esac

# A FULL RESET is the other tempting shortcut and is worse: RIS (ESC c) and
# `tput reset` drop the scrollback the user is trying to get back to, along
# with the palette and the window title.
case $_seen in
*'^[c'*) fail "term-restore sends RIS (ESC c), a full terminal reset. That
discards the scrollback this whole exercise exists to return the user to." ;;
esac

# --- IDEMPOTENT ---------------------------------------------------------
# latch runs it on every transport return without asking whether it was needed,
# which is only defensible if running it twice equals running it once.
_raw2=$T/raw2
script -qc "sh $HOOK; sh $HOOK" "$_raw2" >/dev/null 2>&1 || true
_n1=$(grep -c . "$_raw" 2>/dev/null || echo 0)
[ -s "$_raw2" ] || fail "the second run captured nothing"
case $(cat -v "$_raw2") in
*'^[[?1049l'*) ;;
*) fail "running term-restore twice stopped emitting the resets" ;;
esac
[ "$_n1" -ge 1 ] || fail "the first capture was empty"

pass
