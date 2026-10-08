#!/bin/sh
# test/mux-hook-lab.t - run test/lab against whatever this box can bring up.
#
# WHY THE SUITE RUNS IT AT ALL. The lab is the only thing that can verify a
# focus hook against a real compositor or a toast hook against a real
# notification daemon, and a lab nobody runs is decoration: that is this
# package's oldest rule, the one `mux check` exists for, pointed at the
# harness. Left purely explicit it would rot, and the first anybody would
# know is the next time somebody tried to use it.
#
# AND IT SKIPS LOUDLY ON A BOX WITH NOTHING, which is most boxes: both CI
# runners have no compositor, so this is a no-op there. The skip names what
# was missing rather than going quiet, because "a flake that fails is
# annoying and one that SKIPS is invisible" has cost this suite real time.
#
# THE COST IS ABOUT 9 SECONDS PER ENVIRONMENT, measured, which is why it runs
# the whole matrix rather than a subset: the suite is parallel and already
# carries tests that drive a real tmux. The expensive, explicit thing is
# still `sh test/lab/lab run`, which prints every assertion; this asserts
# only the verdict.
#
# ITS SCRATCH ROOT IS INSIDE $T, so two concurrent suite runs cannot share a
# compositor socket. The one piece that is GLOBAL is the X11 display number,
# and env/x11 refuses loudly rather than searching for a free one.
set -eu
_name=mux-hook-lab
. "$(dirname "$0")/harness_lib"

LAB=$HERE/test/lab
[ -x "$LAB/lab" ] || fail "test/lab/lab is missing or not executable, so the
hook lab cannot be driven at all"

# THE INVENTORY IS ASKED FIRST, because it is also an assertion: `list` has
# to answer without a scratch directory, which it could not do at first (the
# environments demanded LAB_DIR at source time, so asking what a box can run
# required inventing somewhere to run it).
MUX_LAB_DIR=$T/lab "$LAB/lab" list >"$T/list" 2>"$T/list.err" \
  || fail "lab list failed:
$(sed 's/^/  /' "$T/list.err")"
grep -q '^environments' "$T/list" || fail "lab list printed no environment
section, so its output has changed shape and the parse below is blind:
$(sed 's/^/  /' "$T/list")"

_avail=$(grep -c ' available ' "$T/list" || :)
if [ "$_avail" -eq 0 ]; then
  # NAMED, NOT SILENT: the apt line for each missing piece is the whole
  # value of the skip, and it is what turns "the lab does not run here" into
  # a shopping list.
  printf 'skip %s (no environment or daemon available)\n' "$_name"
  sed 's/^/     /' "$T/list"
  exit 0
fi

# BOUNDED, because every probe here waits on something external: a
# compositor claiming a socket, a daemon claiming a bus name, a window
# appearing. A poll that never finishes would hang the runner rather than
# failing it, which test/mutate's own header warns about and this suite has
# paid 151 seconds for once.
# NOT `$T/run`, WHICH IS THE SANDBOX'S OWN XDG_RUNTIME_DIR. harness_lib pins
# it there, so a log file of that name collides with the directory every
# compositor in the lab puts its socket in, and the failure reads as the lab
# producing no output.
_rc=0
if command -v timeout >/dev/null 2>&1; then
  MUX_LAB_DIR=$T/lab timeout 300 "$LAB/lab" run \
    >"$T/labrun" 2>&1 || _rc=$?
else
  MUX_LAB_DIR=$T/lab "$LAB/lab" run >"$T/labrun" 2>&1 || _rc=$?
fi
[ "$_rc" -ne 124 ] || fail "the lab did not finish in 300s. The probes poll
for a window, a socket and a bus name; one of those never arrived:
$(tail -15 "$T/labrun")"
[ "$_rc" -eq 0 ] || fail "the lab reported failures:
$(sed 's/^/  /' "$T/labrun")"

# AND IT MUST HAVE ASSERTED SOMETHING. The lab's own `run` refuses when no
# environment was available, which covers the empty case, but not a probe
# that passed vacuously by making no assertions at all: that is how a
# rewritten probe would read as green forever. Counting the `ok` lines is
# what catches it.
_oks=$(grep -c '^    ok ' "$T/labrun" || :)
[ "$_oks" -ge 4 ] || fail "the lab passed with only $_oks assertions, which
is fewer than one environment's focus probe alone makes. A probe that
asserts nothing reports success:
$(sed 's/^/  /' "$T/labrun")"

pass "$_oks assertions across $_avail available environment(s)/daemon(s)"
