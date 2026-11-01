#!/bin/sh
# setup-system.t - the MACHINE-WIDE mode, `setup.sh <verb> --system`: a
# root-owned, closed payload at /opt/mux with its links under /usr/local, and
# a mode switch that removes the sudo caller's user-mode copy. No test may run
# as root, so everything goes through DESTDIR, which stages the system tree
# under a scratch root exactly as a packager would.
_name=setup-system
. "$(dirname "$0")/harness_lib"     # HERE=repo root, T=scratch, fail/pass

D=$T/dest
# THE UMASK IS PINNED SO THE CLOSING IS THE INSTALLER'S DOING. cp -R copies a
# file's mode through the caller's umask, so under 022 the tree comes out
# closed anyway and the closedness assertions below would pass with the
# installer's chmod deleted. 007 leaves group-write on and world-read off,
# which is wrong in both directions the installer must fix.
umask 007
sysrun() { env DESTDIR="$D" NO_COLOR=1 sh "$HERE/setup.sh" "$@"; }

# --- THE FLAG IS REFUSED WHERE IT MEANS NOTHING ---------------------------
# A verb with no system mode that silently ignored `--system` would do the
# user-mode thing while the caller believed otherwise: the accident the
# installer's argument guard exists for.
_rc=0; sh "$HERE/setup.sh" version --system >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "version --system was not refused (rc $_rc)"
_rc=0; sysrun install --system extra >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "install --system extra was not refused (rc $_rc)"
[ ! -e "$D/opt/mux" ] || fail "a refused install still wrote $D/opt/mux"

# --- NOT ROOT AND NO DESTDIR: REFUSED, WITH THE REMEDY --------------------
if [ "$(id -u)" != 0 ]; then
  _rc=0
  _o=$(env -u DESTDIR sh "$HERE/setup.sh" install --system 2>&1) || _rc=$?
  [ "$_rc" = 1 ] || fail "a non-root --system install was not refused: $_o"
  case $_o in
    *"sudo sh setup.sh install --system"*) ;;
    *) fail "the refusal does not name the remedy: $_o" ;;
  esac
fi

# --- A USER-MODE COPY FOR THE SUDO CALLER, to be switched away ------------
# getent is stubbed so SUDO_USER resolves to a scratch home: the switch runs
# as root inside a real user's home, so this is the half worth proving.
U=$T/uhome
mkdir -p "$T/stub" "$U/.config/tmux"
printf '#!/bin/sh\necho "tester:x:1000:1000::%s:/bin/sh"\n' "$U" \
  >"$T/stub/getent"
chmod +x "$T/stub/getent"
env PREFIX="$U/.local" XDG_BIN_HOME="$U/.local/bin" \
  XDG_DATA_HOME="$U/.local/share" XDG_CONFIG_HOME="$U/.config" \
  MUX_STATE="$U/state" NO_COLOR=1 \
  sh "$HERE/setup.sh" install >/dev/null 2>&1 || fail "user install errored"
[ -L "$U/.local/bin/mux" ] || fail "fixture: no user-mode link to switch"
mkdir -p "$U/.local/share/mux/venv/bin"   # the notifier's, which must stay
printf 'source-file ~/.local/share/mux/mux.tmux\n' \
  >"$U/.config/tmux/tmux.conf"
cp "$U/.config/tmux/tmux.conf" "$T/conf.before"

# --- INSTALL: ONE CLOSED TREE, LINKS TO ITS FINAL PATH --------------------
_o=$(env PATH="$T/stub:$PATH" SUDO_USER=tester DESTDIR="$D" NO_COLOR=1 \
  sh "$HERE/setup.sh" install --system 2>&1) || fail "system install: $_o"
[ -d "$D/opt/mux" ] && [ ! -L "$D/opt/mux" ] \
  || fail "no payload tree at $D/opt/mux"
[ -f "$D/opt/mux/bin/mux" ] && [ -d "$D/opt/mux/share/themes" ] \
  || fail "the system payload is not the shipped tree"

# THE LINK CARRIES /opt/mux, NOT THE STAGE: a staged package whose links
# point into the staging directory ships dangling links.
[ "$(readlink "$D/usr/local/bin/mux")" = /opt/mux/bin/mux ] \
  || fail "bin link is not the final path: $(readlink "$D/usr/local/bin/mux")"
[ "$(readlink "$D/usr/local/share/man/man1/mux.1")" \
  = /opt/mux/man/man1/mux.1 ] || fail "man link is not the final path"

# CLOSED: every user runs it and nobody but root may change it.
_open=$(find "$D/opt/mux/" ! -type l \( -perm -0002 -o -perm -0020 \) \
  -print | head -1)
[ -z "$_open" ] || fail "the system payload is writable by group/other: $_open"
_unread=$(find "$D/opt/mux/" ! -type l ! -perm -0004 -print | head -1)
[ -z "$_unread" ] || fail "the system payload is not world-readable: $_unread"

# AND IT RUNS FROM THERE, by self-location, which is the one mechanism.
"$D/opt/mux/bin/mux" -V >/dev/null 2>&1 \
  || fail "the system payload does not run by itself"

# NOTHING PER-USER WAS TOUCHED AS ROOT: no log, no config README, no
# ~/.local for the caller running it.
[ ! -e "$MUX_STATE/mux.log" ] || fail "a system install wrote a per-user log"
[ ! -e "$HOME/.config/mux/README" ] \
  || fail "a system install wrote a per-user config README"

# --- THE MODE SWITCH -------------------------------------------------------
[ ! -e "$U/.local/bin/mux" ] && [ ! -L "$U/.local/bin/mux" ] \
  || fail "the user-mode command survived the switch (two copies on PATH)"
[ ! -e "$U/.local/share/mux/bin" ] \
  || fail "the user-mode payload's code survived the switch"
[ ! -e "$U/.local/share/man/man1/mux.1" ] \
  && [ ! -L "$U/.local/share/man/man1/mux.1" ] \
  || fail "the user-mode man link survived the switch"
[ -d "$U/.local/share/mux/venv/bin" ] \
  || fail "the switch removed the per-user notifier's venv"
cmp -s "$U/.config/tmux/tmux.conf" "$T/conf.before" \
  || fail "the switch EDITED the user's tmux.conf"
case $_o in
  *"source-file /opt/mux/share/mux.tmux"*) ;;
  *) fail "the stale tmux.conf line was not named with its new spelling:
$_o" ;;
esac

# --- CHECK --------------------------------------------------------------------
# tmux may be absent in a sandbox, so assert the lines rather than the rc.
env PATH="$T/stub:$PATH" SUDO_USER=tester DESTDIR="$D" NO_COLOR=1 \
  sh "$HERE/setup.sh" check --system >"$T/out" 2>&1 || :
for _w in 'links into the payload' 'self-contained tree' \
    'root-owned and closed' 'no user-mode copy for tester'; do
  grep -q "$_w" "$T/out" || fail "check --system lacks [$_w]: $(cat "$T/out")"
done
grep -q 'FAIL.*two copies\|FAIL.*closed' "$T/out" \
  && fail "check --system failed on a clean install: $(cat "$T/out")"

# AN OPEN FILE IS A FAIL, named.
chmod g+w "$D/opt/mux/bin/mux"
_rc=0; sysrun check --system >"$T/out" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && grep -q 'not root-owned and closed' "$T/out" \
  || fail "a group-writable payload passed check: $(cat "$T/out")"
chmod g-w "$D/opt/mux/bin/mux"

# A USER-MODE COPY BESIDE IT IS A FAIL, named, from the system side ...
mkdir -p "$U/.local/bin"; ln -s x "$U/.local/bin/mux"
_rc=0
env PATH="$T/stub:$PATH" SUDO_USER=tester DESTDIR="$D" NO_COLOR=1 \
  sh "$HERE/setup.sh" check --system >"$T/out" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && grep -q 'two copies' "$T/out" \
  || fail "a user copy beside the system one passed: $(cat "$T/out")"
rm -f "$U/.local/bin/mux"

# ... and from the user side, which is the one a provisioner with no sudo
# caller relies on.
env PREFIX="$T/p" XDG_BIN_HOME="$T/p/bin" XDG_DATA_HOME="$T/p/share" \
  DESTDIR="$D" NO_COLOR=1 sh "$HERE/setup.sh" check >"$T/out" 2>&1 || :
grep -q 'a system install .* exists too' "$T/out" \
  || fail "a user-mode check did not name the system copy: $(cat "$T/out")"

# --- PATHS: ONLY THE MACHINE'S ROOTS --------------------------------------
_p=$(sysrun paths --system)
case $_p in
  *config*|*state*|*cache*|*runtime*|*venv*)
    fail "paths --system names a per-user root: $_p" ;;
esac
case $_p in
  *"$D/opt/mux"*) ;; *) fail "paths --system has no payload: $_p" ;;
esac

# --- UNINSTALL ---------------------------------------------------------------
sysrun uninstall --system >/dev/null 2>&1 || fail "system uninstall errored"
[ ! -e "$D/opt/mux" ] || fail "uninstall left $D/opt/mux"
[ ! -L "$D/usr/local/bin/mux" ] || fail "uninstall left the bin link"
[ ! -L "$D/usr/local/share/man/man1/mux.1" ] || fail "uninstall left man"
[ -d "$U/.local/share/mux/venv" ] \
  || fail "a system uninstall reached into a user's files"

pass
