#!/bin/sh
# test/lint.t - shellcheck over every shell file in the package.
#
# This is a TEST, not a separate lint target, for one reason: a lint you have
# to remember to run is a lint that stops being run. Riding the *.t glob means
# `sh test/run` and `./setup.sh test` both enforce it, and CI gets it free.
#
# It SKIPS when shellcheck is absent rather than failing, because the package's
# stated floor is "a shell and the repo checkout" (see test/run) and mux has no
# runtime dependency beyond tmux. A missing linter must not make a correct
# checkout look broken.
#
# WHY LINT AT ALL, given `dash -n` already runs on every edit: they see
# different classes. `dash -n` accepts anything syntactically valid, including
# every word-splitting bug mux has shipped.
#
# But be precise about how much this buys, because it is easy to overclaim and
# then trust a net with a hole in it. MEASURED, with `-s sh`:
#
#     for x in $*                 SC2048     CAUGHT
#     for x in $(tmux ls)         --         NOT CAUGHT
#     for x in $set               --         NOT CAUGHT
#     case " $set " in *" $n "*)  --         NOT CAUGHT
#
# So of the four places "a session name is not a word" shipped -- mux-cycle,
# mux-next-blocked, the hidden-set membership test, and `mux resume` -- this
# check would have found exactly ONE, the `$*` in resume, which is in fact how
# that one WAS found. An external audit found two by reading the code; the
# other two needed tests. shellcheck is a floor, not the net: test/mux-session-
# names.t is what actually holds that class down.
#
# Its real value is the bugs nobody is looking for -- an unquoted expansion in
# an `rm` path, a `local` that is not POSIX, a masked return value.
#
# The configuration (../.shellcheckrc) disables only what is systematically
# wrong about THIS codebase, each with its reason written down. Anything
# intentional but rare is disabled INLINE at the site, so a second, ACCIDENTAL
# instance of the same pattern still fails here.
set -eu
_name=lint
. "$(dirname "$0")/lib.sh"

command -v shellcheck >/dev/null 2>&1 || {
	printf 'skip %s (no shellcheck)\n' "$_name"; exit 0; }

# Every shell file, found by EXTENSION or by SHEBANG -- most of mux's programs
# are extensionless (bin/mux, libexec/mux-check), so a glob alone would miss
# the bulk of the package and quietly lint almost nothing.
_list=$T/files
: >"$_list"
find "$HERE/bin" "$HERE/libexec" "$HERE/test" "$HERE/share" "$HERE/indicator" \
	-type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
	case $_f in
	*.sh|*.t) printf '%s\n' "$_f" ;;
	*.py|*.tmux|*.md|*.toml|*/.git/*) ;;
	*)	# A shebang naming sh/dash/bash, and nothing else.
		case "$(head -c 64 -- "$_f" 2>/dev/null | head -1)" in
		'#!'*/sh|'#!'*/dash|'#!'*/bash|'#!'*env\ sh|'#!'*env\ dash)
			printf '%s\n' "$_f" ;;
		esac ;;
	esac
done >>"$_list"
printf '%s\n' "$HERE/setup.sh" "$HERE/indicator/setup.sh" >>"$_list"
LC_ALL=C sort -u "$_list" -o "$_list"

# A floor on the count. Without it, a find that matched NOTHING (a layout
# change, a bad case arm above) would lint zero files and report a triumphant
# pass -- the failure mode this whole file exists to prevent, reproduced one
# level up. 40 is well under the current count and well over any plausible
# accident.
_n=$(wc -l <"$_list")
[ "$_n" -ge 40 ] || fail "only $_n shell files found; the discovery is broken"

_out=$T/out
# Run from the repo root so shellcheck finds .shellcheckrc, and pass the list
# through `xargs -0` so no filename is ever word-split (mux lives in a path
# with no spaces today, but that is exactly the assumption this suite exists
# to stop making). -0 rather than GNU's -d '\n': BSD xargs has the former and
# not the latter, and shellcheck runs on machines that are not Linux.
( cd "$HERE" && tr '\n' '\0' <"$_list" \
	| xargs -0 shellcheck -s sh -f gcc -- ) >"$_out" 2>&1 || true
if [ -s "$_out" ]; then
	printf 'FAIL %s: shellcheck found %s issue(s) across %s files:\n' \
		"$_name" "$(wc -l <"$_out")" "$_n" >&2
	sed 's|^'"$HERE"'/||' "$_out" >&2
	printf '\nFix it, or -- if it is intentional -- add an inline\n' >&2
	printf '# shellcheck disable=SCxxxx with the reason at the site.\n' >&2
	exit 1
fi

# --- a rule shellcheck does not have: redirection ORDER --------------------
# `cmd <"$f" 2>/dev/null` does NOT silence a missing $f. Redirections apply
# left to right, so the OPEN fails while stderr is still the terminal, and the
# SHELL prints `cannot open ...` before cmd ever runs -- cmd's own 2>/dev/null
# is attached too late to cover it. `cmd 2>/dev/null <"$f"` is correct.
#
# Three shipped: `stty size </dev/tty` (every context with no controlling
# terminal -- cron, a systemd unit, this suite -- got a spurious error on a
# path built to fall through), and two on agent-state RACE paths, where a file
# pruned between the glob and the read is the normal case, not the exception.
# Each looks deliberately silenced, which is what makes it worth a machine
# check rather than a reviewer's eye.
_bad=$T/order
# The second grep drops COMMENT lines -- including the ones just above,
# which describe the bad shape and would otherwise report this file. A line
# with a TRAILING comment is still checked; only a comment-only line is not.
( cd "$HERE" && grep -rnE '<[^ <]+ +2>/dev/null' \
	bin libexec test share setup.sh 2>/dev/null \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_bad" || true
if [ -s "$_bad" ]; then
	printf 'FAIL %s: input redirect BEFORE its 2>/dev/null:\n' "$_name" >&2
	sed 's/^/  /' "$_bad" >&2
	printf 'Put 2>/dev/null first; it does not silence a failing open.\n' >&2
	exit 1
fi

# --- the exit-code contract, mechanically -------------------------------
# mux uses exactly 0, 1, 2 and 3. The ABSENCE of everything else is what lets a
# caller attribute 255 to ssh and 127 to a missing binary rather than to mux,
# which is what `latch` will classify retries on and how a fleet mid-upgrade
# avoids reading as half-broken. test/mux-exit.t pins what today's verbs return;
# this holds the rule against code nobody has written yet, which a per-verb test
# cannot do.
#
# Literal codes only. A handful of sites exit through a variable (`exit "$RC"`
# in mux-check, `exit "${1:-2}"` in usage), and those are covered behaviourally
# instead -- a grep cannot evaluate them, and pretending otherwise would be a
# guard that looks stronger than it is.
#
# Whole-line COMMENTS are excluded, and they have to be: the files that classify
# a FOREIGN exit code have to name it to explain themselves, and mux-latch
# documenting "ssh exits 255" is the opposite of mux exiting 255. A trailing
# comment on a real line is still caught, so the exclusion is as narrow as it
# can be made with a grep.
#
# share/latch/ IS A DIFFERENT CONTRACT and is checked separately below, not
# merely excluded. A latch hook is not a mux command: it answers a QUESTION in
# three states (0 yes, 1 no, 78 cannot tell), and 78 is the whole point --
# "cannot tell" has to be distinguishable from "no" or an edge nobody can check
# gets reported as fine. Exempting the directory with a hole would let a hook
# invent a fourth code; a rule of its own does not.
_ec=$T/exitcodes
( cd "$HERE" && grep -rnE '\bexit [0-9]+' bin libexec share setup.sh \
	2>/dev/null | grep -vE '\bexit [0123]\b' \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
	| grep -v '^share/latch/' ) >"$_ec" || true
if [ -s "$_ec" ]; then
	printf 'FAIL %s: an exit code outside the 0/1/2 contract:\n' "$_name" >&2
	sed 's/^/  /' "$_ec" >&2
	printf 'mux exits 0 (answered), 1 (refused, reason on stderr),\n' >&2
	printf '2 (usage/unknown verb) or 3 (the name is not known here).\n' >&2
	printf 'Anything else makes 255 and 127 ambiguous for a remote\n' >&2
	printf 'caller. See test/mux-exit.t.\n' >&2
	exit 1
fi

# --- the HOOK contract: a latch hook answers 0, 1 or 78, and nothing else ---
_hc=$T/hookcodes
( cd "$HERE" && grep -rnE '\bexit [0-9]+' share/latch 2>/dev/null \
	| grep -vE '\bexit (0|1|78)\b' \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_hc" || true
if [ -s "$_hc" ]; then
	printf 'FAIL %s: a latch hook used an exit code outside 0/1/78:\n' \
		"$_name" >&2
	sed 's/^/  /' "$_hc" >&2
	printf 'A hook answers 0 (yes), 1 (no) or 78 (cannot tell). A fourth\n' >&2
	printf 'code is read as "cannot tell" by latch, so it is silently\n' >&2
	printf 'indistinguishable from 78 and says something it does not mean.\n' >&2
	exit 1
fi

# Every shipped hook must be EXECUTABLE. A hook that is present and unrunnable
# resolves by name, then fails to run, and latch reports the state it could not
# determine rather than the install that is broken.
for _h in "$HERE"/share/latch/*; do
	[ -e "$_h" ] || continue
	[ -x "$_h" ] || fail "share/latch/$(basename "$_h") is not executable;
a hook that cannot run is a hook latch resolves and then cannot use"
done

printf 'ok   %s (%s files clean)\n' "$_name" "$_n"
exit 0
