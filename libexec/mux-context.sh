#!/bin/sh
# mux-context.sh -- the mux CONTEXT seam.
#
# mux core knows nothing about any particular notion of "context" (a
# work/personal split, a k8s namespace, a git host, ...). It asks an OPTIONAL
# hook -- $MUX_DIR/context, an executable -- and falls back to a single default
# context when none is installed. This file is the ONE place that knows the
# hook's contract, so every consumer (bin/mux, mux-style, mux-themes) reads the
# same answer the same way.
#
# Why a hook and not a data file: classifying a layout or picking the isolation
# socket may need to RUN a test against a live process, which a static file
# cannot do. Keeping the test in an executable hook lets that logic -- which for
# an integrator may be security-load-bearing -- live entirely in the integrator
# and out of mux core.
#
# The hook is an executable with three verbs; each is optional to implement, and
# an absent hook (the standalone case) yields a single default context:
#
#   context env [PID]   emit the context of PID's process (default: the caller).
#                       Whitelisted `key value` lines (value = rest of line, so
#                       a label may contain spaces); unknown keys ignored:
#                         socket <name>   tmux -L suffix (isolation); ""=default
#                         side   <token>  opaque; drives layout filtering + tag
#                         label  <text>   banner / title text ("" = no banner)
#                         banner <style>  tmux style for the banner ("" = none)
#                         theme  <name>   default theme for this context
#   context side ROOT   emit the side token a layout rooted at ROOT belongs to,
#                       or `shared` (visible in every context). ROOT may be "".
#   context sockets     emit the -L socket name of every NON-default context
#                       server the hook can address (one per line), so `reload`
#                       and palette sync reach them all regardless of the
#                       caller's own side.
#
# Output is PARSED against a key whitelist, never eval'd.

: "${MUX_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/mux}"
MUX_CTX_HOOK=${MUX_CTX_HOOK:-$MUX_DIR/context}

# Populate MUX_CTX_SOCKET/SIDE/LABEL/BANNER/THEME from the hook's `env` verb for
# PID (default: this process). No hook, or a silent/failing hook -> the default
# context: default server, side `default`, no banner, mux's own default theme.
mux_ctx_env() {         # [PID]
	MUX_CTX_SOCKET=''
	MUX_CTX_SIDE=default
	MUX_CTX_LABEL=''
	MUX_CTX_BANNER=''
	MUX_CTX_THEME=''
	[ -x "$MUX_CTX_HOOK" ] || return 0
	_cx=$("$MUX_CTX_HOOK" env "${1:-$$}" 2>/dev/null) || return 0
	# Heredoc (not a pipe) so the while loop runs in THIS shell and the
	# assignments below persist; <<- strips the leading tabs.
	while read -r _k _v; do
		case $_k in
		socket) MUX_CTX_SOCKET=$_v ;;
		side)   [ -n "$_v" ] && MUX_CTX_SIDE=$_v ;;
		label)  MUX_CTX_LABEL=$_v ;;
		banner) MUX_CTX_BANNER=$_v ;;
		theme)  MUX_CTX_THEME=$_v ;;
		esac
	done <<-EOF
	$_cx
	EOF
	return 0
}

# Echo the side token a layout rooted at ROOT belongs to (`shared` = every
# context). No hook -> everything is shared, so a single-context mux shows all.
mux_ctx_side() {        # ROOT
	[ -x "$MUX_CTX_HOOK" ] || { echo shared; return 0; }
	_s=$("$MUX_CTX_HOOK" side "${1:-}" 2>/dev/null) || _s=
	echo "${_s:-shared}"
}

# Echo every non-default context socket the hook can address, one per line (for
# reload / palette sync). No hook -> nothing (only the default server exists).
mux_ctx_sockets() {
	[ -x "$MUX_CTX_HOOK" ] || return 0
	"$MUX_CTX_HOOK" sockets 2>/dev/null || true
}
