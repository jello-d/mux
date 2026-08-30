# test/lib.sh - a tiny harness for mux's shell tests, sourced by each *.t.
#
# Sets HERE (the repo root, so a test sources libexec/<lib>.sh), a private
# scratch dir T (removed on exit), and fail/pass. A test sets _name, sources
# this, then the library under test. Pure string logic; nothing outside T is
# touched. POSIX sh; run one test with `sh test/<name>.t` or all with test/run.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
_name=${_name:-$(basename -- "$0")}
fail() { printf 'FAIL %s: %s\n' "$_name" "$1" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$_name"; exit 0; }
