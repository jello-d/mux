#!/bin/sh
# setup.t - setup.sh install -> assert links -> check -> uninstall -> assert
# gone, all against a scratch PREFIX. Nothing outside the sandbox is touched.
_name=setup
. "$(dirname "$0")/lib.sh"     # HERE=repo root, T=scratch, fail/pass

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

# uninstall: every link removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$T/bin/mux" ] && fail "bin/mux link not removed"
[ -e "$T/libexec/mux" ] && fail "libexec/mux link not removed"
[ -e "$T/share/mux" ] && fail "share/mux link not removed"

pass
