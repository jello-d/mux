#!/bin/sh
# test/mux-indicator.t - run the indicator's Python tests from the shell suite.
#
# The indicator is mux's only non-shell component, and it had NO tests at all
# until now. A coverage sweep kept reporting indicator/setup.sh as the last dark
# file while the Python beside it was equally dark and did not even show up,
# because the sweep only instruments shell.
#
# THE TESTS LIVE IN PYTHON, NEXT TO THE CODE (indicator/tests/, stdlib unittest,
# no new dependency), because they assert things only Python can reach: the
# ARGB byte permutation, that two states never render alike, that an unknown
# state word cannot kill the daemon. This file exists so `sh test/run` is still
# the ONE entry point -- a second command to remember is a command that stops
# being run.
#
# IT SKIPS RATHER THAN FAILS when the deps are absent, matching test/lint.t
# (no shellcheck) and test/mux-sane.t (no script). dbus-next and Pillow are
# optional extras for an optional component; a box that never installed the
# tray must not have a red suite because of it.
set -eu
_name=mux-indicator
. "$(dirname "$0")/lib.sh"

IND=$HERE/indicator
[ -d "$IND/tests" ] || fail "indicator/tests is missing"

# A python that can import the deps. The venv setup.sh builds is the usual one;
# a system python with them installed works too. Checked by IMPORTING rather
# than by looking for a venv directory, since a half-built venv is exactly the
# case that should skip rather than fail confusingly.
_py=
# $HOME_REAL, not $HOME: lib.sh pins HOME inside the scratch dir so no test
# can write outside it, and the venv lives in the user's actual home. This
# only READS it, which is what HOME_REAL exists for.
for _c in "${MUX_INDICATOR_VENV:-$HOME_REAL/.venvs/mux-indicator}/bin/python" \
          python3 python; do
	command -v "$_c" >/dev/null 2>&1 || [ -x "$_c" ] || continue
	if "$_c" -c 'import dbus_next, PIL' >/dev/null 2>&1; then
		_py=$_c
		break
	fi
done
[ -n "$_py" ] || {
	printf 'skip %s (no python with dbus-next + Pillow)\n' "$_name"
	exit 0; }

# -t . so `from mux_indicator...` resolves against the package, not the tests.
_out=$T/out
if ( cd "$IND" && "$_py" -m unittest discover -s tests -t . ) \
	>"$_out" 2>&1; then
	_n=$(sed -n 's/^Ran \([0-9]*\) test.*/\1/p' "$_out" | tail -1)
	# A run that asserted NOTHING is a failure, the same rule the rest of the
	# suite applies to itself: an empty discover exits 0 and looks like a pass.
	[ -n "$_n" ] && [ "$_n" -ge 20 ] || fail "only ${_n:-0} python test(s)
ran, and there were 28 when this was written. A discover that matches nothing
exits 0, so a rename or a broken import reads exactly like a clean run."
	printf 'ok   %s (%s python tests, %s)\n' "$_name" "$_n" \
		"$(basename "$(dirname "$(dirname "$_py")")")"
	exit 0
fi

printf 'FAIL %s: the indicator python tests failed\n' "$_name" >&2
sed 's/^/  /' "$_out" >&2
exit 1
