#!/bin/sh
# test/mux-theme.t - `mux theme`, the whole subsystem, which had no test.
#
# Six functions were never once called by the suite: cmd_theme, _theme_show,
# _theme_cycle, _theme_apply, _theme_remember and _persist_theme. That matters
# more than the usual untested verb because this one WRITES: it persists your
# choice into a profile, and a theme set by hand is a decision, so losing or
# duplicating it is losing work rather than losing a pixel.
#
# Two things carry most of the risk and both are pinned below:
#
#   the CYCLE arithmetic. next/prev walk a sorted list with wraparound, and an
#   off-by-one makes cycling skip a theme or stick on one. Silent either way:
#   you would just think you had fewer themes.
#
#   the PERSIST rewrite. It replaces an existing `theme` line in place and
#   appends when there is none. Getting that wrong either duplicates the line
#   (two answers, one file) or eats a neighbouring line.
#
# A controlled theme set is installed rather than the shipped 25, so ordering
# assertions say what they mean instead of encoding today's theme names.
set -eu
_name=mux-theme
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/profiles.d" "$T/proj"
BO=$T/conf/profiles.d/proj.profile
cp -R "$HERE/share/." "$T/share/" 2>/dev/null || mkdir -p "$T/share"
rm -f "$T/share/themes"/*.theme
mkdir -p "$T/share/themes"
# Real theme KEYS, copied from a shipped theme's shape. A fixture that models
# the format wrongly is the trap this suite has paid for before: these were
# `status-style` at first, which mux-themes rejects as a bad key, so the apply
# path was erroring while the test still passed.
for _t in aaa bbb ccc; do
	cat >"$T/share/themes/$_t.theme" <<'THEME'
bar     bg=#0a2a44 fg=#b8d8f0
window  fg=#08202e bg=#ffc020 bold
accent  fg=#ffc020
border  fg=#2f5a7e
select  fg=#08202e bg=#ffd460
prompt  bg=#123f60 fg=#b8d8f0
THEME
done

# The stub keeps @mux-theme in a file, so setting it is observable and reading
# it back drives the cycle from a real "current".
OPT=$T/opt; export OPT
: >"$OPT"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*"set-option"*@mux-theme*) printf '%s\n' "${*##* }" >"$OPT" ;;
*"show-options"*@mux-theme*) cat "$OPT" 2>/dev/null ;;
*display-message*session_name*) printf 'proj\n' ;;
*display-message*pane_pid*)     printf '4242\n' ;;
*display-message*pane_height*)  printf '10\n' ;;
*list-panes*)                   printf '%%1 1\n' ;;
*list-sessions*)                printf 'proj\n' ;;
*window_index*)                 printf '0\n' ;;
*pane_id*)                      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

# Inside a session (the normal case for theme).
mux() {
	( cd "$T/proj" && env TMUX=/tmp/fake/global,1,0 PATH="$T/bin:$PATH" \
		MUX_DIR="$T/conf" MUX_SHARE="$T/share" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
# Outside any session.
mux_out() {
	( cd "$T/proj" && env -u TMUX PATH="$T/bin:$PATH" \
		MUX_DIR="$T/conf" MUX_SHARE="$T/share" MUX_CACHE="$T/cache" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
applied() { cat "$OPT" 2>/dev/null; }
reset() { : >"$OPT"; rm -f "$T/conf/profiles" "$T/conf/profiles.d"/*.profile; }

# --- with no argument it REPORTS, and changes nothing --------------------
reset
_o=$(mux theme)
case $_o in
*aaa*bbb*ccc*) ;;
*) fail "theme with no argument did not list what is available: $_o" ;;
esac
[ -z "$(applied)" ] || fail "a bare 'mux theme' applied something: $(applied)"

# --- an unknown theme is refused, and applies nothing --------------------
# The guard that keeps an arbitrary string out of the persisted profile.
reset
_rc=0; _o=$(mux theme nosuchtheme) || _rc=$?
[ "$_rc" -ne 0 ] || fail "an unknown theme exited 0"
case $_o in *"unknown theme"*) ;; *) fail "unhelpful refusal: $_o" ;; esac
[ -z "$(applied)" ] || fail "an unknown theme was still applied"
[ ! -f "$T/conf/profiles" ] || fail "an unknown theme was still remembered"

# --- outside a session it refuses rather than guessing ------------------
reset
_rc=0; _o=$(mux_out theme aaa) || _rc=$?
[ "$_rc" -ne 0 ] || fail "setting a theme outside a session exited 0"
case $_o in
*"must run in a session"*) ;;
*) fail "the refusal did not say why: $_o" ;;
esac

# --- a named theme is applied AND remembered ----------------------------
# Remembering is the point: a theme set by hand is a decision, and the profile
# table is the only place decisions live.
reset
_o=$(mux theme bbb)
[ "$(applied)" = bbb ] || fail "the theme was not applied: [$(applied)]"
case $_o in *remembered*) ;; *) fail "the theme was not remembered: $_o" ;; esac
grep -q 'bbb' "$T/conf/profiles" \
	|| fail "the choice did not reach the profile table"

# --- the CYCLE arithmetic, in both directions and across both edges -----
# From a known current, next/prev are the neighbours in the sorted list.
cyc() { : >"$OPT"; printf '%s\n' "$1" >"$OPT"; mux theme "$2" >/dev/null
	applied; }
[ "$(cyc aaa next)" = bbb ] || fail "next from aaa should be bbb"
[ "$(cyc bbb next)" = ccc ] || fail "next from bbb should be ccc"
[ "$(cyc ccc next)" = aaa ] || fail "next from ccc should WRAP to aaa"
[ "$(cyc ccc prev)" = bbb ] || fail "prev from ccc should be bbb"
[ "$(cyc bbb prev)" = aaa ] || fail "prev from bbb should be aaa"
[ "$(cyc aaa prev)" = ccc ] || fail "prev from aaa should WRAP to ccc"

# A current that is not in the list at all (a theme file removed since it was
# chosen) must still land somewhere sensible rather than sticking or failing.
[ "$(cyc zzz next)" = aaa ] || fail "next from an unknown current should be 1st"
[ "$(cyc zzz prev)" = ccc ] \
	|| fail "prev from an unknown current should be the last"

# Cycling the whole list returns to where it started: nothing skipped, nothing
# visited twice. This is the property an off-by-one actually breaks.
: >"$OPT"; printf 'aaa\n' >"$OPT"
mux theme next >/dev/null; mux theme next >/dev/null; mux theme next >/dev/null
[ "$(applied)" = aaa ] || fail "three nexts over three themes did not return
to the start: [$(applied)]"

# --- the persisted `theme` line is REPLACED, never duplicated -----------
# A breakout profile takes the theme in place. Two theme lines in one file is
# two answers to one question, and nothing would say which won.
reset
printf 'window code\ntheme   aaa\npane agent\n' >"$BO"
mux theme ccc >/dev/null
[ "$(grep -c '^theme' "$BO")" -eq 1 ] \
	|| fail "the profile gained a second theme line:
$(cat "$BO")"
grep -q '^theme[[:space:]]*ccc' "$BO" \
	|| fail "the theme line was not updated:
$(cat "$BO")"
# ... and the surrounding lines survive the rewrite untouched.
grep -qx 'window code' "$BO" \
	|| fail "the rewrite ate a preceding line"
grep -qx 'pane agent' "$BO" \
	|| fail "the rewrite ate a following line"

# --- ... and APPENDED when the profile has none ------------------------
reset
printf 'window code\npane agent\n' >"$BO"
mux theme bbb >/dev/null
[ "$(grep -c '^theme' "$BO")" -eq 1 ] \
	|| fail "appending did not produce exactly one theme line"
grep -q 'bbb' "$BO" || fail "the appended theme is wrong"

# --- setting the same theme twice is idempotent ------------------------
mux theme bbb >/dev/null
[ "$(grep -c '^theme' "$BO")" -eq 1 ] \
	|| fail "re-setting the same theme duplicated the line"

pass
