#!/bin/sh
# test/mux-context.t - the mux CONTEXT seam, mux_ctx_* in
# libexec/mux-context.sh: the adapter mapping mux core onto an optional
# $MUX_DIR/context hook. A fake hook stands in for the real one -- nothing on
# the box is touched.
set -eu
_name=mux-context
. "$(dirname "$0")/lib.sh"

# Point the adapter at a hook we write per-case under $T, then source it fresh.
MUX_CTX_HOOK=$T/context
export MUX_CTX_HOOK
. "$HERE/libexec/mux-context.sh"

# write_hook BODY : install $BODY as the executable hook.
write_hook() {
	printf '#!/bin/sh\n%s\n' "$1" > "$MUX_CTX_HOOK"
	chmod +x "$MUX_CTX_HOOK"
}
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- a hook that emits a full (marked) context ------------------------------
write_hook 'case "$1" in
env) printf "socket wk\nside work\nlabel MARK: demo team\n"
     printf "banner bold\ntheme orange\n" ;;
side) case "$2" in
      "") echo shared ;; /w/*) echo work ;; *) echo personal ;;
      esac ;;
sockets) echo wk ;;
esac'
mux_ctx_env
eq env-socket "$MUX_CTX_SOCKET" wk
eq env-side   "$MUX_CTX_SIDE"   work
# a label with spaces must survive intact (value = rest of the line).
eq env-label  "$MUX_CTX_LABEL"  "MARK: demo team"
eq env-banner "$MUX_CTX_BANNER" bold
eq env-theme  "$MUX_CTX_THEME"  orange
eq side-root-w   "$(mux_ctx_side /w/x)"  work
eq side-root-o   "$(mux_ctx_side /other)" personal
eq side-rootless "$(mux_ctx_side '')"    shared
eq sockets       "$(mux_ctx_sockets)"    wk

# --- a minimal (single-side) hook: only `side` ------------------------------
write_hook 'case "$1" in env) echo "side personal" ;; sockets) : ;; esac'
mux_ctx_env
eq min-side   "$MUX_CTX_SIDE"   personal
eq min-socket "$MUX_CTX_SOCKET" ''
eq min-label  "$MUX_CTX_LABEL"  ''
eq min-sockets "$(mux_ctx_sockets)" ''

# --- unknown keys are ignored, side falls back to default when empty --------
write_hook 'case "$1" in env) printf "bogus xyz\nsocket s1\nside \n" ;; esac'
mux_ctx_env
eq wl-socket "$MUX_CTX_SOCKET" s1
eq wl-side   "$MUX_CTX_SIDE"   default

# --- no hook at all (the standalone default context) ------------------------
rm -f "$MUX_CTX_HOOK"
mux_ctx_env
eq no-socket  "$MUX_CTX_SOCKET" ''
eq no-side    "$MUX_CTX_SIDE"   default
eq no-label   "$MUX_CTX_LABEL"  ''
eq no-side-fn "$(mux_ctx_side /anything)" shared
eq no-sockets "$(mux_ctx_sockets)"        ''

pass
