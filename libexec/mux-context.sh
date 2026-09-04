#!/bin/sh
# mux-context.sh -- the mux CONTEXT seam. Sourced (functions only).
#
# mux core knows nothing about any particular notion of "context" (a
# work/personal split, a k8s namespace, a git host, ...). It asks an OPTIONAL
# command for ONE WORD and decides everything else itself.
#
#   context   a named situation, identified by a TOKEN.
#   partition an isolation unit. Sessions in different partitions are mutually
#             invisible. Defaults to the context's own token, so contexts are
#             isolated by default; several may name one partition to share it.
#   global    the reserved token AND partition of the unconfigured baseline.
#
# THE ENTIRE INTEGRATION SURFACE is one command, named in $MUX_DIR/config:
#
#     context-command   severance current
#
# It prints one line: a token. Empty output or a non-zero exit means `global`.
# No sockets, no styles, no themes, no path classification -- the integrator
# reports IDENTITY, mux decides presentation and isolation. That is deliberate:
# the previous contract made the integrator supply a tmux style string for the
# banner (so a missing style silently removed a safety reminder) while
# withholding the one structural fact mux needed.
#
# SETTINGS resolve in three levels, merged in order, last wins per key:
#
#   1. built-in defaults below -- BEHAVIOUR ONLY, never a location. That is
#      what keeps `scan` from leaking between partitions, and it is a decision
#      about data rather than a branch in this resolver.
#   2. partitions/<partition>.partition -- what this partition shares
#   3. contexts/<token>.context         -- what is unique to this context
#
# The same key set is legal in either file: where you put a key IS the
# statement of its scope, so there is no per-key classification to learn.

: "${MUX_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/mux}"

# --- resolved state, readable by callers after mux_ctx_resolve --------------
MUX_CTX_TOKEN=global
MUX_CTX_PARTITION=global
# The theme when nothing at all has an opinion: no profile, no context, and
# derivation switched off. A last resort, not a default -- MUX_CFG_theme is
# deliberately EMPTY by default so that "a context set a theme" is
# distinguishable from "nobody did", which is what lets an explicit context
# theme beat the name hash.
MUX_THEME_FALLBACK=purple

# A token becomes a socket name and a path component, so it is validated as a
# DNS label before use: lowercase alphanumeric and hyphens, not leading or
# trailing, 63 max. An integrator returning `../..` would otherwise choose
# where mux writes. Invalid is an ERROR, never a silent fall back to global --
# a typo'd token quietly becoming the baseline would put work sessions in the
# personal partition.
mux_ctx_valid() {       # <token>
	case $1 in
	''|*[!a-z0-9-]*|-*|*-) return 1 ;;
	esac
	[ "${#1}" -le 63 ]
}

# One value from $MUX_DIR/config (invariants only; today just context-command).
mux_ctx_conf() {        # <key>
	_cf=$MUX_DIR/config
	[ -f "$_cf" ] || return 0
	sed -e 's/\r$//' -e '/^[[:space:]]*#/d' "$_cf" \
	| awk -v k="$1" '$1==k{sub("^"k"[ \t]+",""); print; exit}'
}

# Merge one settings file over the current values. Unknown keys are IGNORED
# rather than fatal: a newer mux writing a key this one does not know must not
# break an older one, and these files are commonly generated.
_mux_ctx_merge() {      # <file>
	[ -f "$1" ] || return 0
	_first_scan=1
	while read -r _k _v; do
		case $_k in
		''|'#'*) continue ;;
		partition) MUX_CFG_partition=$_v ;;
		label)     MUX_CFG_label=$_v ;;
		theme)     MUX_CFG_theme=$_v ;;
		derive)    MUX_CFG_derive=$_v ;;
		agent)     MUX_CFG_agent=$_v ;;
		layout)    MUX_CFG_layout=$_v ;;
		host-chip) MUX_CFG_host_chip=$_v ;;
		scan)
			# Repeatable WITHIN a file, but a file REPLACES the list
			# from earlier levels -- last wins per key, where the
			# key's value is the whole list. So a context can drop
			# its partition's roots rather than only add to them.
			if [ "$_first_scan" = 1 ]; then
				MUX_CFG_scan=$_v; _first_scan=0
			else
				MUX_CFG_scan="$MUX_CFG_scan
$_v"
			fi ;;
		esac
	done <<EOF
$(sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$1")
EOF
	return 0
}

# Resolve the context for PID (default: this process) and merge its settings.
# Sets MUX_CTX_TOKEN, MUX_CTX_PARTITION and every MUX_CFG_*.
mux_ctx_resolve() {     # [PID]
	# 1. built-in defaults. BEHAVIOUR ONLY -- no scan, no label.
	MUX_CFG_partition=
	MUX_CFG_label=
	MUX_CFG_theme=
	MUX_CFG_derive=hash
	MUX_CFG_agent=claude
	MUX_CFG_layout=default
	MUX_CFG_host_chip=on
	MUX_CFG_scan=
	MUX_CTX_TOKEN=global
	MUX_CTX_ERR=

	_cc=$(mux_ctx_conf context-command)
	# A bare name resolves against $MUX_DIR before PATH. The config file is
	# commonly shared between machines through a dotfiles repo, so it must
	# not have to carry an absolute path that is only right on one of them.
	case $_cc in
	'' | */*) ;;
	*) [ -x "$MUX_DIR/$_cc" ] && _cc=$MUX_DIR/$_cc ;;
	esac
	if [ -n "$_cc" ]; then
		_t=$($_cc "${1:-$$}" 2>/dev/null | head -1 | tr -d '[:space:]') \
			|| _t=
		if [ -n "$_t" ]; then
			if mux_ctx_valid "$_t"; then
				MUX_CTX_TOKEN=$_t
			else
				MUX_CTX_ERR="invalid context token: $_t"
				return 1
			fi
		fi
	fi

	# The context file names the partition; absent, the partition IS the
	# token, so contexts are isolated by default.
	_ctxf=$(_mux_ctx_file contexts "$MUX_CTX_TOKEN" .context)
	if [ -n "$_ctxf" ]; then
		MUX_CFG_partition=$(sed -e 's/\r$//' -e '/^[[:space:]]*#/d' \
			"$_ctxf" \
			| awk '$1=="partition"{print $2; exit}')
	fi
	[ -n "$MUX_CFG_partition" ] || MUX_CFG_partition=$MUX_CTX_TOKEN
	mux_ctx_valid "$MUX_CFG_partition" || {
		MUX_CTX_ERR="invalid partition: $MUX_CFG_partition"
		return 1
	}
	MUX_CTX_PARTITION=$MUX_CFG_partition

	# 2. the partition, then 3. the context.
	_partf=$(_mux_ctx_file partitions "$MUX_CTX_PARTITION" .partition)
	_mux_ctx_merge "$_partf"
	_mux_ctx_merge "$_ctxf"
	MUX_CTX_PARTITION=$MUX_CFG_partition

	# Neither file: nothing knows this context. The caller decides whether
	# to warn (never from here -- the status bar calls this every tick).
	MUX_CTX_UNKNOWN=0
	[ -z "$_partf" ] && [ -z "$_ctxf" ] && MUX_CTX_UNKNOWN=1
	return 0
}

# $MUX_DIR over $MUX_SHARE, like every other package-data read.
_mux_ctx_file() {       # <kind> <name> <ext>
	if [ -f "$MUX_DIR/$1/$2$3" ]; then printf '%s' "$MUX_DIR/$1/$2$3"
	elif [ -n "${MUX_SHARE:-}" ] && [ -f "$MUX_SHARE/$1/$2$3" ]; then
		printf '%s' "$MUX_SHARE/$1/$2$3"
	fi
}

# Every partition mux knows of, one per line: whatever has a .partition file,
# plus the one we are in. Used by `reload` and the palette sync to reach every
# running server regardless of which partition the caller is in.
mux_ctx_partitions() {
	{
		for _d in "$MUX_DIR/partitions" "${MUX_SHARE:-}/partitions"; do
			[ -d "$_d" ] || continue
			for _f in "$_d"/*.partition; do
				[ -e "$_f" ] || continue
				_b=${_f##*/}; printf '%s\n' "${_b%.partition}"
			done
		done
		[ -n "${MUX_CTX_PARTITION:-}" ] && printf '%s\n' \
			"$MUX_CTX_PARTITION"
	} | LC_ALL=C sort -u | grep . || true
}

# The tmux -L name for a partition. An implementation detail of the partition:
# nobody outside mux names a socket, and `global` is an ordinary name here --
# it gets its own socket like any other, so the isolation story has no
# exception in it.
mux_ctx_socket() {      # [partition]
	printf '%s' "${1:-$MUX_CTX_PARTITION}"
}
