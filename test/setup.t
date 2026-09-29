#!/bin/sh
# setup.t - setup.sh install -> assert links -> check -> uninstall -> assert
# gone, all against a scratch PREFIX. Nothing outside the sandbox is touched.
_name=setup
. "$(dirname "$0")/harness_lib"     # HERE=repo root, T=scratch, fail/pass

run() {
  env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
    sh "$HERE/setup.sh" "$@"
}

# install: bin + the namespaced libexec/share + the man page all linked
run install >/dev/null 2>&1 || fail "install errored"
[ "$(readlink "$T/bin/mux")" = "$HERE/bin/mux" ] || fail "bin/mux not linked"
[ "$(readlink "$T/libexec/mux")" = "$HERE/libexec" ] || fail "libexec/mux link"
[ "$(readlink "$T/share/mux")" = "$HERE/share" ] || fail "share/mux link"
[ -e "$T/share/man/man1/mux.1" ] || fail "man page not linked"

# check: the install-symlink lines are green (tmux may be absent in a sandbox,
# so tolerate a non-zero overall rc and assert the install line directly)
run check >"$T/out" 2>&1 || true
grep -q 'bin/mux linked' "$T/out" || fail "check missing the bin/mux OK line"

# --- AN INSTALLED INDICATOR THAT HAS FALLEN BEHIND IS SAID, NOT FIXED -------
# The indicator is a separate package that core neither installs nor owns, but
# it POLLS a mux contract (`mux agent status`, JSON), and a skew there fails
# silently: a daemon built against an older contract keeps polling and just
# publishes fewer items, which reads as "that partition is gone" rather than as
# a version problem. So a core install says so.
#
# NOT A RESTART, which is the part worth asserting: restarting would not help,
# because what is stale is the daemon's own code rather than anything it caches
# from core -- it re-execs `mux` every poll. And not an install, which is a pip
# operation wanting a network that core deliberately has no part of.
#
# SILENT WITH NO INDICATOR INSTALLED, first, because an optional sub-package
# must not make the core install noisy for everyone who does not use it.
run install >"$T/out" 2>&1 || fail "reinstall errored"
grep -q 'tray indicator' "$T/out" && fail "the indicator notice fired with no
indicator installed; an optional sub-package must stay silent:
$(cat "$T/out")"

# ... and said when one IS installed and does not match. The drift verdict is
# the INDICATOR's own check (package vs installed vs the running daemon), so
# this is content-based rather than keyed on a version somebody must remember
# to bump. Here the sandbox venv does not exist at all, which is one of the
# three answers that check distinguishes.
: >"$T/bin/mux-indicator"
run install >"$T/out" 2>&1 || fail "install errored with an indicator present"
grep -q 'tray indicator' "$T/out" || fail "an installed indicator that does not
match the package was not reported, so a silent tray skew is the default:
$(cat "$T/out")"
grep -q 'setup.sh indicator' "$T/out" || fail "the notice did not name the
command that fixes it; a gap named without a remedy invites two different fixes"
rm -f "$T/bin/mux-indicator"

# uninstall: every link removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$T/bin/mux" ] && fail "bin/mux link not removed"
[ -e "$T/libexec/mux" ] && fail "libexec/mux link not removed"
[ -e "$T/share/mux" ] && fail "share/mux link not removed"

pass
