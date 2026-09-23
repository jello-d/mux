#!/bin/sh
# mux-hosts.sh - WHICH COLOUR IDENTIFIES A HOST. Sourced (functions only).
#
# Two consumers now, which is why it is a lib: `mux style` paints the status
# chip with it, and `mux host-color` hands it to the tray indicator, so a
# per-host tray item is the same colour as that host's chip. Two copies of this
# rule would drift, and the drift would be silent -- the bar and the tray would
# simply disagree about which machine is which, and neither would look broken.
#
# THE ANSWER IS A PAIR, fg and bg, never one colour. That is not decoration: the
# backgrounds are deliberately dark so light text sits on them, so a bg alone is
# unusable as ink and an fg alone is unusable as a fill. Anything drawing with
# this must use both, exactly as the status chip does.

# mux_host_name -> this machine's short name, as the chip and map key use it.
mux_host_name() {
	hostname -s 2>/dev/null || hostname
}

# mux_host_style [HOST] -> the tmux style for HOST's chip, e.g.
# `fg=colour252,bg=colour236`. An explicit `<host> <style>` line in
# $MUX_DIR/hosts wins; otherwise one of eight readable pairs is chosen by the
# name, so an unconfigured host is stable and legible rather than absent.
#
# DETERMINISTIC BY NAME, via cksum: the same host gets the same colour on every
# machine that ever renders it, with no shared state and nothing to configure.
# That is what lets the tray on one box colour a REMOTE host correctly.
mux_host_style() {      # [host]
	_hsn=${1:-$(mux_host_name)}
	_hstyle=
	_hostsf=$MUX_DIR/hosts
	if [ -r "$_hostsf" ]; then
		_hstyle=$(mux_conf_clean <"$_hostsf" \
			| awk -v h="$_hsn" '$1==h{print $2; exit}')
	fi
	if [ -z "$_hstyle" ]; then
		_hn=$(printf '%s' "$_hsn" | cksum \
			| { read -r _c _r; echo $((_c%8)); })
		case $_hn in
		0) _hstyle=fg=colour252,bg=colour236 ;;
		1) _hstyle=fg=colour230,bg=colour238 ;;
		2) _hstyle=fg=colour231,bg=colour24  ;;
		3) _hstyle=fg=colour231,bg=colour88  ;;
		4) _hstyle=fg=colour016,bg=colour109 ;;
		5) _hstyle=fg=colour231,bg=colour54  ;;
		6) _hstyle=fg=colour016,bg=colour179 ;;
		7) _hstyle=fg=colour231,bg=colour22  ;;
		esac
	fi
	printf '%s' "$_hstyle"
}

# _mux_hex COLOUR -> #rrggbb for a tmux colour word, or empty if it cannot be
# resolved. Accepts `colourN`, `colorN`, a bare number, or a literal #rrggbb.
#
# WHY MUX CONVERTS AND NOT THE CALLER: a tmux style is tmux's dialect, and
# `colour236` is a pixel value only if you know the xterm-256 layout. Handing
# a drawing program `bg=colour236` makes it learn that layout, which is a
# second copy of a standard nobody should own twice. It is arithmetic, not a
# table: 16-231 is a 6x6x6 cube on the levels below, 232-255 even greyscale.
#
# 0-15 ARE NOT COMPUTABLE and are deliberately absent. They are the terminal's
# OWN sixteen, remapped by every theme, so there is no correct answer -- only
# the one the user's terminal happens to use. A caller gets nothing for those
# rather than a confident guess; the eight derived pairs above use only 16+, so
# the common path never hits it. (colour016 IS in range: 16, the cube's black.)
_mux_hex() {            # <colour word>
	_hc=$1
	case $_hc in
	'#'*) printf '%s' "$_hc"; return 0 ;;
	colour*) _hc=${_hc#colour} ;;
	color*)  _hc=${_hc#color} ;;
	esac
	case $_hc in
	''|*[!0-9]*) return 0 ;;
	esac
	# Strip leading zeros BY HAND. `$((10#$_hc))` is a bashism dash rejects
	# outright, and plain `$((016))` is OCTAL -- 14, not 16 -- so the style
	# `fg=colour016` in the derived pairs would silently paint the wrong
	# colour. Both wrong answers are quiet, which is why this is spelled out.
	while :; do
		case $_hc in
		0?*) _hc=${_hc#0} ;;
		*)   break ;;
		esac
	done
	if [ "$_hc" -ge 232 ] && [ "$_hc" -le 255 ]; then
		_hv=$((8 + (_hc - 232) * 10))
		printf '#%02x%02x%02x' "$_hv" "$_hv" "$_hv"
		return 0
	fi
	if [ "$_hc" -ge 16 ] && [ "$_hc" -le 231 ]; then
		_hi=$((_hc - 16))
		_hr=$((_hi / 36))
		_hg=$(((_hi % 36) / 6))
		_hb=$((_hi % 6))
		printf '#%02x%02x%02x' \
			"$(_mux_cube "$_hr")" "$(_mux_cube "$_hg")" \
			"$(_mux_cube "$_hb")"
		return 0
	fi
	return 0
}

# The six cube levels. Not evenly spaced: the jump from 0 to 95 is the
# standard's own, and getting it wrong shifts every dark colour.
_mux_cube() {           # <0-5>
	case $1 in
	0) printf '0' ;;   1) printf '95' ;;  2) printf '135' ;;
	3) printf '175' ;; 4) printf '215' ;; 5) printf '255' ;;
	esac
}

# mux_host_hex [HOST] -> `<fg-hex> <bg-hex>` for HOST's chip, or nothing when
# either half cannot be resolved (a 0-15 colour, or a style with no fg/bg).
# Nothing rather than half an answer: a caller drawing ink with no fill, or a
# fill with no ink, produces something worse than not drawing at all.
mux_host_hex() {        # [host]
	_hs=$(mux_host_style "${1:-}")
	_hf=$(printf '%s' "$_hs" | tr ',' '\n' \
		| awk -F= '$1=="fg"{print $2; exit}')
	_hb=$(printf '%s' "$_hs" | tr ',' '\n' \
		| awk -F= '$1=="bg"{print $2; exit}')
	_hfh=$(_mux_hex "$_hf")
	_hbh=$(_mux_hex "$_hb")
	[ -n "$_hfh" ] && [ -n "$_hbh" ] || return 0
	printf '%s %s' "$_hfh" "$_hbh"
}
