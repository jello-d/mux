#!/bin/sh
# test/mutants.t - the corpus must still describe THIS code.
#
# `test/mutate` is the real check, and it copies the tree and runs tests per
# record, so it is minutes rather than seconds and stays a separate command.
# This is the cheap half that rides the suite, and it exists for one specific
# rot: A RECORD WHOSE TARGET LINE NO LONGER EXISTS LEAVES THE FILE UNTOUCHED.
# Every named test then passes, and from outside that is indistinguishable from
# "the guard does not bite".
#
# It runs no mutation and executes nothing. It only asserts that the corpus and
# the code still agree, so the moment someone edits a guarded line this fails
# and names the record to update.
set -eu
_name=mutants
. "$(dirname "$0")/lib.sh"

CORPUS=$HERE/test/mutants
[ -f "$CORPUS" ] || fail "no mutation corpus at test/mutants"
[ -x "$HERE/test/mutate" ] || fail "test/mutate is missing or not executable"

_n=0
M_N=; M_F=; M_T=; M_O=
_check() {
	[ -n "$M_N" ] || return 0
	_n=$((_n + 1))
	[ -n "$M_F" ] || fail "record '$M_N' names no file"
	[ -n "$M_T" ] || fail "record '$M_N' names no test. A mutation with
nothing to kill it can never report anything, so the corpus would grow while
proving less"
	[ -n "$M_O" ] || fail "record '$M_N' has no line to remove"
	[ -f "$HERE/$M_F" ] \
		|| fail "record '$M_N' targets $M_F, which does not exist"
	for _t in $M_T; do
		[ -f "$HERE/test/$_t.t" ] || fail "record '$M_N' names test
'$_t', which does not exist. A record naming a deleted test can never kill
anything and will report SURVIVED forever"
	done

	# THE LOAD-BEARING PAIR. -F is a fixed string and -x is whole-line, so
	# this matches exactly what the driver's awk matches: no regex, nothing
	# to clash with the `||`, `*`, `$` and trailing backslashes these lines
	# are full of.
	_c=$(grep -Fxc -- "$M_O" "$HERE/$M_F" 2>/dev/null || true)
	[ "$_c" != 0 ] || fail "record '$M_N' wants to remove a line that is no
longer in $M_F:

  [$M_O]

The mutation would leave the file UNTOUCHED, every named test would pass, and
the driver would report the guard as covered when nothing changed at all.
Update the record to the line as it now reads."
	# Ambiguity is as bad as absence, and subtler. bin/mux carries two
	# identical `if [ "$_have_astate" -eq 1 ]` lines and only one is in
	# cmd_ls; mutating the wrong one by hand left the suite green and read
	# as "the guard is uncovered" when the guard was never touched.
	[ "$_c" = 1 ] || fail "record '$M_N' targets a line that appears $_c
times in $M_F:

  [$M_O]

The driver mutates the FIRST occurrence, which may not be the one the named
test covers. Target a unique line instead."
	M_N=; M_F=; M_T=; M_O=
}

while IFS= read -r _line; do
	case "$_line" in
	'= '*) _check; M_N=${_line#??} ;;
	'f '*) M_F=${_line#??} ;;
	't '*) M_T=${_line#??} ;;
	'- '*) M_O=${_line#??} ;;
	esac
done <"$CORPUS"
_check

# A corpus that silently emptied would validate perfectly. Same rule the rest of
# the suite applies to itself: a run that reached no verdict is a failure.
[ "$_n" -ge 17 ] || fail "the corpus holds only $_n record(s). It covered 19
guards when written, so this has lost coverage rather than gained it"

# EVERY GUARDED FILE MUST BE ONE THE PACKAGE SHIPS. A record pointing at a
# fixture or a scratch path would validate forever and protect nothing.
while IFS= read -r _line; do
	case "$_line" in
	'f '*)
		case "${_line#??}" in
		bin/*|libexec/*|share/*|setup.sh) ;;
		*) fail "a record targets '${_line#??}', which is not shipped
code. The corpus must guard what the package installs, not a test fixture" ;;
		esac ;;
	esac
done <"$CORPUS"

# Every record SHOULD carry an expected-failure fragment. Without one, `killed`
# only means some assertion died, and a mutation that breaks an earlier
# unrelated check counts as coverage -- which has happened here. Not yet a hard
# requirement, because a couple of records legitimately have no stable message
# to match, but the count is held so it cannot quietly erode.
_m=$(grep -c '^m ' "$CORPUS" 2>/dev/null || true)
[ "$_m" -ge 16 ] || fail "only $_m of $_n records name the failure they expect.
Without that, a mutation breaking an unrelated assertion still reports killed"

pass
