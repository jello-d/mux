# test/lib.sh - a tiny harness for mux's shell tests, sourced by each *.t.
#
# Sets HERE (the repo root, so a test sources libexec/<lib>.sh), a private
# scratch dir T (removed on exit), a HOME pinned inside it, and fail/pass. A
# test sets _name, sources this, then the library under test. Pure string logic;
# nothing outside T is touched. POSIX sh; run one test with `sh test/<name>.t`
# or all with test/run.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM

# HOME IS PINNED INSIDE T, and that one line is what makes the claim above
# ("nothing outside T is touched") actually true rather than aspirational.
#
# It was aspirational, and got caught: every location mux derives is
# $HOME-relative by default, and each test pinned the ones it KNEW about
# ($MUX_DIR, $MUX_CACHE) by name. When the session set moved to $MUX_STATE
# (~/.local/state/mux) no existing test had any reason to know the variable
# existed, so the suite wrote four fixture session files into the REAL state
# directory and three tests went red for the wrong reason.
#
# Pinning the variables one at a time would have fixed those three tests and
# left the next new location exposed. Pinning HOME fixes every location mux will
# ever derive, including ones nobody has written yet, which is the only version
# of this that cannot rot. A test that needs a real path still has $HERE.
# The REAL home, captured before the pin. A test that needs to READ something
# optional the user installed -- the indicator's venv, say -- has no other way
# to find it once HOME points into T. Reading is all it is for: the pin's
# guarantee is that nothing is WRITTEN outside T, and that still holds.
HOME_REAL=$HOME
export HOME_REAL
HOME=$T/home
export HOME
mkdir -p "$HOME"

# The session set, pinned explicitly as well. HOME above already keeps it inside
# T, but a fixture is easier to read as $T/state/sessions.global than as
# $T/home/.local/state/mux/sessions.global, and it mirrors how each test pins
# $MUX_CACHE. The HOME pin is the guard; this is the convenience.
MUX_STATE=$T/state
export MUX_STATE
mkdir -p "$MUX_STATE"
_name=${_name:-$(basename -- "$0")}
fail() { printf 'FAIL %s: %s\n' "$_name" "$1" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$_name"; exit 0; }

# agent_rec FILE STATE PANE EPOCH SESSION [NOTIF] -- write ONE per-pane
# agent-state record, in the current format, to FILE.
#
#     state window pane epoch notif SESSION
#
# The session comes LAST so a name containing a space reads back whole with a
# single `read -r _st _w _p _e _nid _ss` (see libexec/mux-agent-state.sh).
# notif is `-` when absent, never empty: an empty field collapses into the
# whitespace run and shifts every field after it.
#
# CENTRALISED BECAUSE IT WAS NOT. When the session name moved to the last
# field, the fixtures were hand-written in four test files and two were missed.
# One went red on main and stayed red; the other kept PASSING, because its
# stale record parsed as a session literally named `x` and the assertion only
# counted sessions -- so it agreed with a format it no longer used. A fixture
# that encodes the format independently of the code is a test that can drift
# without going red, which is the failure this whole suite exists to prevent.
# One writer here means the next format change breaks compilation, not silence.
agent_rec() {   # FILE STATE PANE EPOCH SESSION [NOTIF]
	mkdir -p -- "$(dirname -- "$1")"
	printf '%s 0 %s %s %s %s\n' "$2" "$3" "$4" "${6:--}" "$5" >"$1"
}
