#!/bin/sh
# test/mux-style.t - libexec/mux-style, 189 lines that had NEVER executed once
# under the suite. Measured, not guessed: the whole file was dark.
#
# It is wired to status-left, so it runs every status-interval on every client,
# which makes it the hottest path in the package and the one where a mistake is
# most visible. Four properties carry it:
#
#   -q PRINTS NOTHING. The attach/create hooks run it quietly. tmux run-shell
#   displays a command's stdout in a VIEW-MODE buffer over the pane, freezing it
#   on a [0/0] snapshot until a key is pressed -- so a banner escaping under -q
#   does not merely look wrong, it wedges the pane the instant a marked session
#   attaches. That is a bug this file's own header records having shipped.
#
#   MUX OWNS THE BANNER STYLE. It used to come from the integrator, so an
#   integrator supplying a label and no style got no banner and no title prefix
#   at all: a safety reminder that vanished when its colours were omitted.
#
#   @mux-prefix IS CLEARED, not just set. Leaving a context has to remove the
#   marker, or the terminal title keeps claiming a boundary that is gone.
#
#   set_opt WRITES ONLY ON CHANGE. Running every tick, an unconditional
#   set-option would redraw the bar continuously.
set -eu
_name=mux-style
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/contexts"

# tmux stub: global options answer from a table, per-session options live in a
# file so a second run sees what the first one set, and every set-option is
# recorded so "did not write" is assertable.
OPTS=$T/opts; SETLOG=$T/setlog
export OPTS SETLOG
: >"$OPTS"; : >"$SETLOG"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$1 $2" in
"show-options -gqv")
	# global theme options: enough for the happy path
	case "$3" in
	@theme-purple-bar)    printf 'bg=colour54,fg=colour231\n' ;;
	@theme-purple-window) printf 'fg=colour16,bg=colour141\n' ;;
	@theme-purple-accent) printf 'fg=colour141\n' ;;
	esac
	exit 0 ;;
esac
case "$*" in
"show-options -qv -t "*)
	_o=${*##* }
	awk -F'\t' -v k="$_o" '$1==k{print $2; exit}' "$OPTS" 2>/dev/null ;;
"set-option -t "*)
	# set-option -t SESSION NAME VALUE
	shift 3; _n=$1; shift; _v=$*
	printf 'set %s\n' "$_n" >>"$SETLOG"
	# Exact field compare, not a grep pattern: an option name with a regex
	# metacharacter would otherwise never be replaced (see mux-click.t).
	awk -F'\t' -v k="$_n" '$1 != k' "$OPTS" >"$OPTS.t" 2>/dev/null || :
	mv -f "$OPTS.t" "$OPTS"
	printf '%s\t%s\n' "$_n" "$_v" >>"$OPTS" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

# The context hook records the pid it was handed, so we can prove mux-style asks
# about the pane's FOREGROUND process rather than the pane's own shell.
PIDLOG=$T/pidlog; export PIDLOG
cat >"$T/conf/cc" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$PIDLOG"
[ -n "${CTX_TOKEN:-}" ] && printf '%s\n' "$CTX_TOKEN"
exit 0
EOF
chmod +x "$T/conf/cc"
printf 'context-command cc\n' >"$T/conf/config"

style() {
	env PATH="$T/bin:$PATH" MUX_DIR="$T/conf" HOME="$T" \
		"$HERE/libexec/mux-style" "$@" 2>&1
}
opt()  { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$OPTS" 2>/dev/null; }
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would append a
# SECOND zero and every numeric compare would see "0\n0".
sets() { grep -c . "$SETLOG" 2>/dev/null || true; }
reset() { : >"$OPTS"; : >"$SETLOG"; : >"$PIDLOG"; }

# --- a labelled context prints a banner, and marks the title -------------
printf 'label WORK\n' >"$T/conf/contexts/work.context"
reset
_o=$(CTX_TOKEN=work style proj $$)
case $_o in
*"[[WORK]]"*) ;;
*) fail "no banner for a labelled context: [$_o]" ;;
esac
[ "$(opt @mux-prefix)" = "[WORK] " ] \
	|| fail "the title prefix was not set: [$(opt @mux-prefix)]"

# --- MUX owns the style: a label with no style still gets a banner -------
# The regression this guards: the style came from the integrator, so omitting
# colours silently removed the safety reminder entirely.
case $_o in
*'#['*'][[WORK]]'*) ;;
*) fail "the banner carried no style of its own: [$_o]" ;;
esac
# ... and it is loud and theme-neutral rather than inherited from the bar.
case $_o in
*colour196*) ;;
*) fail "the banner style is not mux's fixed loud one: [$_o]" ;;
esac

# --- -q applies the side effects and prints NOTHING ----------------------
# The pane-wedging case. Anything on stdout here lands in a view-mode buffer
# over the pane when a hook runs it.
reset
_o=$(CTX_TOKEN=work style -q proj $$)
[ -z "$_o" ] || fail "-q printed something, which would wedge the pane: [$_o]"
[ "$(opt @mux-prefix)" = "[WORK] " ] \
	|| fail "-q skipped the side effects it exists to apply"
[ -n "$(opt status-style)" ] || fail "-q did not apply the theme"

# --- no label: no banner, and the prefix is CLEARED ---------------------
# Leaving a context must remove the marker, or the title keeps claiming it.
: >"$T/conf/contexts/work.context"      # token resolves, but no label
reset
printf '@mux-prefix\t[STALE] \n' >"$OPTS"
_o=$(CTX_TOKEN=work style proj $$)
case $_o in
*'[['*) fail "a banner appeared for a context with no label: [$_o]" ;;
esac
[ -z "$(opt @mux-prefix)" ] \
	|| fail "a stale title prefix survived: [$(opt @mux-prefix)]"
printf 'label WORK\n' >"$T/conf/contexts/work.context"

# --- set_opt writes only when the value CHANGES ------------------------
# status-left re-runs this every tick; an unconditional set redraws the bar.
reset
CTX_TOKEN=work style -q proj $$ >/dev/null
_first=$(sets)
[ "$_first" -gt 0 ] || fail "the first run set nothing at all"
: >"$SETLOG"
CTX_TOKEN=work style -q proj $$ >/dev/null
[ "$(sets)" -eq 0 ] \
	|| fail "a second identical run still wrote $(sets) option(s)"

# --- the host chip -----------------------------------------------------
# Default: derived from the name, so an unconfigured host still gets a legible
# chip. It must be STABLE, or the bar would flicker between colours per tick.
reset
_o=$(CTX_TOKEN=work style proj $$)
_h=$(hostname -s 2>/dev/null || hostname)
case $_o in
*"$_h"*) ;;
*) fail "the host chip is missing: [$_o]" ;;
esac
_o2=$(CTX_TOKEN=work style proj $$)
[ "$_o" = "$_o2" ] || fail "the chip is not stable across runs"

# An explicit hosts line WINS over the derived colour.
printf '%s fg=colour1,bg=colour2\n' "$_h" >"$T/conf/hosts"
reset
_o=$(CTX_TOKEN=work style proj $$)
case $_o in
*"fg=colour1,bg=colour2"*) ;;
*) fail "an explicit hosts style was ignored: [$_o]" ;;
esac
rm -f "$T/conf/hosts"

# host-chip off suppresses it entirely.
printf 'label WORK\nhost-chip off\n' >"$T/conf/contexts/work.context"
reset
_o=$(CTX_TOKEN=work style proj $$)
case $_o in
*"$_h"*) fail "host-chip off still printed the chip: [$_o]" ;;
esac
printf 'label WORK\n' >"$T/conf/contexts/work.context"

# --- the context is asked about the FOREGROUND process ----------------
# Not the pane's own shell. A context entered inside a running pane is reported
# by no tmux hook, so mux reads tpgid from /proc and asks about THAT.
#
# The truth comes from ps, which knows tpgid without this test re-parsing
# /proc at all. Re-implementing the same field arithmetic here would only prove
# that two copies of one guess agree -- and the first attempt did exactly that,
# indexing the SESSION id instead of tpgid and "failing" against correct code.
reset
CTX_TOKEN=work style -q proj $$ >/dev/null
_asked=$(head -1 "$PIDLOG")
_tp=$(ps -o tpgid= -p $$ 2>/dev/null | tr -d ' ')
case ${_tp:-} in
''|-*|0) # no controlling terminal, so there is no foreground group to find:
	 # the documented fallback is the pane pid itself.
	 [ "$_asked" = "$$" ] \
		|| fail "with no tpgid it should fall back to the pane pid,
asked [$_asked] want [$$]" ;;
*)	 [ "$_asked" = "$_tp" ] \
		|| fail "asked [$_asked], want the foreground group [$_tp]" ;;
esac

# With a KNOWN foreground group, the right field is read. MUX_STYLE_PROC exists
# for this: a test shell has no controlling terminal, so the real tpgid is -1,
# the non-numeric guard fires and $6 is never reached -- which means a wrong
# field index passes unnoticed. It did: mutating $6 to $4 left this file green
# until the seam was added.
#
# The stat line is shaped like the real thing on purpose, including a comm that
# CONTAINS SPACES AND PARENS, since that is exactly why the code splits on the
# LAST ')' rather than counting fields from the start.
reset
mkdir -p "$T/fakeproc/4242"
printf '4242 ((my cmd) (x)) S 1 3 4 5 777 0 0\n' \
	>"$T/fakeproc/4242/stat"
env PATH="$T/bin:$PATH" MUX_DIR="$T/conf" HOME="$T" CTX_TOKEN=work \
	MUX_STYLE_PROC="$T/fakeproc" \
	"$HERE/libexec/mux-style" -q proj 4242 >/dev/null 2>&1
[ "$(head -1 "$PIDLOG")" = 777 ] \
	|| fail "the foreground group was misread: asked [$(head -1 "$PIDLOG")],
the stat line's tpgid is 777"

# A pid with no /proc entry falls back to the pane pid rather than failing: the
# status line must keep drawing for a pane whose process has just exited.
reset
_o=$(CTX_TOKEN=work style -q proj 999999 2>&1) || fail "a dead pid was fatal"
[ "$(head -1 "$PIDLOG")" = 999999 ] \
	|| fail "a dead pid did not fall back: [$(head -1 "$PIDLOG")]"

# --- a missing context hook must not break the status line ------------
# The bar is drawn every tick; a broken overlay is not a reason to lose it.
reset
rm -f "$T/conf/config"
_o=$(style proj $$) || fail "mux-style failed with no context configured"
case $_o in
*"$_h"*) ;;
*) fail "the chip vanished when no context was configured: [$_o]" ;;
esac
[ -n "$(opt status-style)" ] || fail "no theme applied without a context"

pass
