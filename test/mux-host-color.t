#!/bin/sh
# test/mux-host-color.t - the colour pair that identifies a host, as hex.
#
# WHY MUX ANSWERS THIS AT ALL. A per-host tray item has to be the same colour as
# that host's status-bar chip, or the two disagree about which machine is which
# and neither looks broken. So the rule has ONE owner (libexec/mux-hosts.sh,
# which `mux style` also uses) rather than being derived a second time by
# whatever is drawing.
#
# AND WHY HEX RATHER THAN THE TMUX STYLE: `bg=colour236` is a pixel value only
# if you know the xterm-256 layout. Converting here means a drawing program does
# not have to learn a standard nobody should own twice.
#
# THE CONVERSION IS ARITHMETIC, NOT A TABLE, so it is worth pinning: 16-231 is a
# 6x6x6 cube on the levels 0/95/135/175/215/255 (unevenly spaced -- the 0-to-95
# jump is the standard's own and getting it wrong shifts every dark colour), and
# 232-255 is greyscale at 8 + 10n. The values below were cross-checked against
# an independent implementation rather than read off this one.
set -eu
_name=mux-host-color
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/conf"
hc() {   # [host] -> stdout
	env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" host-color "$@" 2>/dev/null
}
rc() {   # [host] -> exit code
	_r=0
	env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" host-color "$@" >/dev/null 2>&1 || _r=$?
	echo "$_r"
}
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- an explicit entry wins, and both halves convert --------------------
cat >"$T/conf/hosts" <<'EOF'
# hostname <tab or space> tmux style
greybox     fg=colour252,bg=colour236
creambox    fg=colour230,bg=#5f3a1a
cubebox     fg=colour231,bg=colour24
zerobox     fg=colour016,bg=colour109
padbox      fg=colour231,bg=colour024
EOF
eq greyscale  "$(hc greybox)"  "#d0d0d0 #303030"
eq literal-bg "$(hc creambox)" "#ffffd7 #5f3a1a"
eq cube       "$(hc cubebox)"  "#ffffff #005f87"
# A LEADING ZERO IS NOT OCTAL HERE, and proving that takes care. `$((016))` IS
# 14 in dash, sh and bash -- measured, not assumed -- while `[ 016 -ge 16 ]` is
# true, so a padded colour sails past the range check and then does arithmetic
# on the wrong number. `$((10#016))` is the usual fix and is a bashism dash
# rejects outright, so the zeros are stripped by hand.
#
# colour016 CANNOT TEST THAT, which is the interesting part: the buggy path
# computes a negative cube index, every component falls through to nothing, and
# printf renders `#000000` -- which is the CORRECT answer for colour016. A
# mutation removing the strip passed against it. colour024 is the case that
# tells them apart: 24 is #005f87, octal 024 is 20 and gives #0000d7.
eq leading-zero "$(hc zerobox)" "#000000 #87afaf"
eq padded-vs-not "$(hc padbox)" "$(hc cubebox)"
eq padded-value  "$(hc padbox)" "#ffffff #005f87"

# --- an UNLISTED host still gets a stable, legible pair -----------------
# Derived from the name, so the box you are sitting at can colour a REMOTE host
# correctly with nothing shared and nothing configured. Stability is the whole
# property: the same name must give the same colour on every machine, forever.
_u=$(hc some-unlisted-host)
case $_u in
'#'??????' #'??????) ;;
*) fail "an unlisted host must still resolve to a hex pair, got [$_u]" ;;
esac
eq stable "$(hc some-unlisted-host)" "$_u"
[ "$(hc other-unlisted-host)" != "$_u" ] \
	|| fail "two different names landed on the same pair. Not fatal (there are
only eight), but if EVERY name collided the derivation would be broken, and
this is the cheapest way to notice."

# --- the two halves are never the same colour --------------------------
# The pair exists so text is legible on its own background. A pair whose fg
# equals its bg is invisible, and the tray would draw a blank tile.
for _h in greybox creambox cubebox zerobox some-unlisted-host a b c d e f g; do
	_p=$(hc "$_h") || continue
	_f=${_p%% *}; _b=${_p##* }
	[ "$_f" != "$_b" ] \
		|| fail "$_h resolved to fg == bg ($_f): a tile drawn with that
pair has invisible ink"
done

# --- IT REFUSES rather than answering half ------------------------------
# Colours 0-15 are the terminal's OWN sixteen, remapped by every theme, so
# there is no correct hex -- only whatever the user's terminal happens to use.
# Guessing would put a wrong colour on a tray item that claims to identify a
# machine, which is worse than drawing nothing.
printf 'ansibox fg=colour7,bg=colour0\n' >>"$T/conf/hosts"
eq refuses "$(rc ansibox)" 1
eq refuses-quietly "$(hc ansibox)" ""

# ... and the refusal SAYS why and what to do, since the fix is a config edit.
_err=$(env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
	"$HERE/bin/mux" host-color ansibox 2>&1 >/dev/null || true)
case $_err in
*"0-15"*) ;;
*) fail "the refusal must explain that 0-15 has no fixed value, got:
$_err" ;;
esac
case $_err in
*hosts*) ;;
*) fail "the refusal must name the file to fix, got:
$_err" ;;
esac

# --- read-only, and it never contacts a tmux server --------------------
# It is safe on a status tick, so it must not need (or start) a server. PATH
# carries no tmux at all here: if the verb reaches for one, it fails.
mkdir -p "$T/bin"
for _c in sed awk grep cut tr cksum hostname printf cat dirname \
		readlink basename command; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
_o=$(env -i PATH="$T/bin" HOME="$HOME" MUX_DIR="$T/conf" \
	MUX_CACHE="$T/cache" "$HERE/bin/mux" host-color greybox 2>&1) \
	|| fail "host-color needs something PATH did not have: $_o"
eq no-tmux "$_o" "#d0d0d0 #303030"

pass
