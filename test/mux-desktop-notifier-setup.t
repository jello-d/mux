#!/bin/sh
# mux-desktop-notifier-setup.t - desktop-notifier/setup.sh, once dark.
#
# A function-level coverage sweep found desktop-notifier/setup.sh completely
# unexecuted: app, service, uninstall and check had never run. It is the single
# source of the install procedure and tackup can delegate to it, so its `check`
# is a contract someone else reads.
#
# SYSTEMCTL IS STUBBED, and that is not tidiness. `setup.sh uninstall` runs
# `systemctl --user disable --now mux-desktop-notifier.service`, and
# the user manager
# knows that unit by NAME regardless of where XDG_CONFIG_HOME points, so a
# test running it unstubbed would stop the developer's actually-running tray.
# The stub also lets the assertions be about what setup.sh DID rather than about
# whatever state this machine happens to be in.
#
# WHAT IS NOT TESTED, said plainly rather than faked: `app` builds a venv and
# pips the package, which needs a network and minutes, and `service` needs a
# real user manager. Stubbing pip would be testing the stub. Those stay
# integration; `setup.sh check` is what reports on them afterwards.
set -eu
_name=mux-desktop-notifier-setup
. "$(dirname "$0")/harness_lib"

SETUP=$HERE/desktop-notifier/setup.sh
[ -x "$SETUP" ] || fail "desktop-notifier/setup.sh is missing or not executable"

mkdir -p "$T/bin" "$T/venv/bin" "$T/xdg"
# `mv` joined this list when the rename's retirement step arrived: the
# curated PATH models exactly the tools the code needs, so it CAUGHT the
# new dependency by failing the migration rather than by anybody noticing.
for _c in sed awk grep cat rm mv mkdir ln cmp install printf dirname \
  basename; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
# Records what it was asked to do and always succeeds, so the script's own
# `|| true` guards are not what makes this pass.
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SCTL"
if [ "${2:-}" = is-enabled ]; then printf '%s\n' "${SCTL_ENABLED:-disabled}"; fi
# `show -p MainPID --value`, which is how the check finds the running daemon.
case "$*" in
*MainPID*) printf '%s\n' "${SCTL_PID:-0}" ;;
*restart*)
  # A restart that FAILS, on demand: the message decides which of the two
  # failure answers the script is supposed to give.
  if [ -n "${SCTL_FAIL:-}" ]; then
    printf '%s\n' "$SCTL_FAIL" >&2
    exit 1
  fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/systemctl"
SCTL=$T/systemctl.log
UNIT=mux-desktop-notifier.service
UNITF=$T/xdg/systemd/user/$UNIT

OUT=; RC=0
run() {   # <verb ...>
  : >"$SCTL"
  RC=0
  OUT=$(env PATH="$T/bin" HOME="$HOME" XDG_CONFIG_HOME="$T/xdg" \
    XDG_STATE_HOME="${STATE_HOME:-$T/state}" \
    MUX_DESKTOP_NOTIFIER_VENV="$T/venv" MUX_DESKTOP_NOTIFIER_BIN="$T/bin" \
    SCTL="$SCTL" SCTL_ENABLED="${SCTL_ENABLED:-disabled}" \
    SCTL_PID="${SCTL_PID:-0}" SCTL_FAIL="${SCTL_FAIL:-}" \
    "$SETUP" "$@" 2>&1) || RC=$?
}
# has PATTERN MESSAGE. NOT `has "$OUT" PATTERN MESSAGE`, which eleven calls in
# this file used to do: `case $OUT in *"$OUT"*)` matches unconditionally, so
# every one of them was VACUOUS: they read as coverage and asserted nothing.
# Found by mutation, which is the only thing that can tell those apart: two
# guards removed from setup.sh SURVIVED against a green suite.
has() {
  [ "$#" -eq 2 ] || fail "has takes PATTERN MESSAGE, got $#: $*"
  case $OUT in *"$1"*) ;; *) fail "$2:
$OUT" ;; esac
}

# --- an unknown verb is a usage error, not a silent install -------------
# The dispatch defaults to `install` when given NOTHING, so a typo'd verb must
# not fall through to it: `setup.sh instal` building a venv and enabling a
# service would be a surprising amount of work for a misspelling.
run bogus-verb
[ "$RC" = 2 ] || fail "an unknown verb must exit 2, got $RC"
has usage "an unknown verb must print the usage"
[ ! -s "$SCTL" ] || fail "an unknown verb touched systemctl:
$(cat "$SCTL")"

# --- check REPORTS, and fails when nothing is installed ----------------
run check
[ "$RC" = 1 ] || fail "check on an empty prefix must exit non-zero, got $RC"
has '[FAIL]' "check must use the [FAIL] marker contract"
case $OUT in
*'[OK]'*) fail "nothing is installed, so nothing should read [OK]:
$OUT" ;;
esac
# It must not FIX anything: an audit that installs is not an audit.
[ ! -e "$T/bin/mux-desktop-notifier" ] || fail "check created the bin symlink"
[ ! -e "$UNITF" ] || fail "check installed the unit file"

# --- the markers are PLAIN when captured -------------------------------
# tackup pipes this through its report styler, which repaints plain markers. If
# check emitted colour when not on a terminal, the styler would be painting
# over escape codes and the output would be mangled in the place a human reads.
case $OUT in
*"$(printf '\033')"*) fail "check emitted ANSI colour into a pipe:
$(printf '%s' "$OUT" | cat -v)" ;;
esac

# --- check turns [OK] as the pieces appear -----------------------------
# Each marker is a distinct question; a check that said [OK] to a box that is
# half-installed would be worse than one that failed, because it sends you
# looking elsewhere.
printf '#!/bin/sh\nexit 0\n' >"$T/venv/bin/mux-desktop-notifier"
chmod +x "$T/venv/bin/mux-desktop-notifier"
run check
has '[OK]' "with the venv app present, at least one marker must pass"
[ "$RC" = 1 ] || fail "still incomplete, so check must still fail"

mkdir -p "$T/xdg/systemd/user"
cp "$HERE/desktop-notifier/$UNIT" "$UNITF"
run check
has "$UNIT current" "a unit file matching the package's must read current"

# A STALE unit must not read as current: the whole point of comparing rather
# than merely existing is that an old copy runs old settings forever.
printf '# drifted\n' >>"$UNITF"
run check
case $OUT in
*"$UNIT current"*) fail "a DRIFTED unit file read as current. cmp exists here
precisely so an edited-then-forgotten unit cannot look installed." ;;
esac
cp "$HERE/desktop-notifier/$UNIT" "$UNITF"

# --- `service` SAYS WHAT IT DID, and the restart is the point -----------
# It used to print "installed + enabled" unconditionally while also running
# `systemctl restart`, so the one action anybody watches for after a code
# change was invisible, and a restart that FAILED printed the same sentence
# as one that worked. Found by a human reading a provisioning run and
# concluding, reasonably, that the daemon had not been restarted. It had.
#
# A message that cannot distinguish success from failure is the same defect as
# a presence check that cannot distinguish installed from working, one layer
# out, and this package already has that rule written down.
run service
[ "$RC" = 0 ] || fail "service should succeed with a working systemctl, got $RC"
grep -q 'restart' "$SCTL" || fail "service never asked systemctl to restart:
$(cat "$SCTL")"
has "RESTARTED" "the restart happened and was not reported:
$OUT"

# NO USER MANAGER IS THE THIRD ANSWER, not a failure: a headless or pre-login
# install cannot start anything, the unit is enabled, and it comes up at the
# next login. That case is the reason the call was wrapped in `|| true` at
# all; the mistake was letting it silence every other case too.
SCTL_FAIL='Failed to connect to bus: No medium found'
run service; unset SCTL_FAIL
[ "$RC" = 0 ] || fail "no user manager is not an error, got $RC"
has "next login" "a headless install did not say when it would start"
case $OUT in
*RESTARTED*) fail "it claimed a RESTART that could not have happened" ;;
esac

# ... and anything else is loud and non-zero, because a service that will not
# start is drift the provisioner has to see.
_jf='Job for mux-desktop-notifier.service failed'
SCTL_FAIL=$_jf run service; unset SCTL_FAIL
[ "$RC" = 1 ] || fail "a failed restart must exit non-zero, got $RC"
has "RESTART FAILED" "a failed restart was not reported as one"
has "OLD code" "the failure did not say what it means for the running daemon"
has "Job for mux-desktop-notifier.service failed" \
  "systemctl's own reason was swallowed"

# --- uninstall removes what it installed, and is idempotent ------------
ln -sf "$T/venv/bin/mux-desktop-notifier" "$T/bin/mux-desktop-notifier"
run uninstall
[ "$RC" = 0 ] || fail "uninstall must succeed, got $RC"
[ ! -e "$UNITF" ] || fail "uninstall left the unit file behind"
[ ! -e "$T/bin/mux-desktop-notifier" ] \
  || fail "uninstall left the bin symlink behind"
grep -q 'disable' "$SCTL" || fail "uninstall never asked systemctl to disable:
$(cat "$SCTL")"

# THE VENV SURVIVES, deliberately: rebuilding it is minutes and a network, so
# uninstall removing it would make a reinstall expensive for no reason.
[ -x "$T/venv/bin/mux-desktop-notifier" ] \
  || fail "uninstall deleted the venv. It says it leaves it in place, and
rebuilding is minutes and a network."
has 'venv' "uninstall should say the venv was left"

# Twice is once. A second run has nothing to remove and must not error.
run uninstall
[ "$RC" = 0 ] || fail "a second uninstall must be a no-op, got $RC"

# --- the INSTALLED CODE is checked, not just its presence -----------------
# THE BUG THIS EXISTS FOR, and it is not hypothetical: northwood ran a copy
# installed on 2026-08-30 for weeks while every marker read [OK]. Everything was
# present, the unit file matched, the service was enabled, and a provisioner
# runs `apply` only when `check` FAILS, so passing is precisely what kept the
# stale code alive. The green check was the thing preventing the fix.
#
# BY CONTENT, NOT BY VERSION, because a version needs someone to remember to
# bump it. This same fleet already watched a version-keyed plugin cache sit
# stale through two full provisions for exactly that reason.
#
# python is STUBBED to answer where the package landed, which is what the real
# check asks it. That keeps this fast and hermetic: building a real venv is
# minutes and a network, and the thing under test is the COMPARISON.
SITE=$T/site/mux_desktop_notifier
mkdir -p "$SITE"
cat >"$T/venv/bin/python" <<EOF
# !/bin/sh The real check asks the interpreter where mux_desktop_notifier lives;
# everything else it asks (the dbus_next/PIL import) just has to succeed.
case "\$*" in
*mux_desktop_notifier*os.path.dirname*) echo "$SITE" ;;
esac
exit 0
EOF
chmod +x "$T/venv/bin/python"

# In step: every package file has an identical installed copy.
for _f in "$HERE"/desktop-notifier/mux_desktop_notifier/*.py; do
  cp "$_f" "$SITE/"; done
run check
has "installed code matches" "identical copies were not reported current"

# DRIFTED: one file differs. This is the northwood case exactly: present,
# importable, wrong.
printf '\n# a local edit\n' >>"$SITE/render.py"
run check
case $OUT in
*"installed code matches"*) fail "a DRIFTED file read as current. The whole
point is that content is compared; presence was already covered above." ;;
esac
has "STALE" "drifted code was not called stale"
has "render.py" "the stale report did not name the file that drifted"
[ "$RC" = 1 ] || fail "stale installed code must fail the check, got $RC.
Passing is what stopped a provisioner from ever re-running apply."
# It must say what to DO. A check that reports drift without the remedy makes
# two reasonable people close it two different ways.
has "setup.sh indicator install" "the stale report named no remedy"

# MISSING: a new module that was never installed. Same verdict as drifted:
# a half-updated install is not a working one.
cp "$HERE"/desktop-notifier/mux_desktop_notifier/render.py "$SITE/render.py"
rm -f "$SITE/sources.py"
run check
has "sources.py" "a MISSING module was not reported"
[ "$RC" = 1 ] || fail "a missing module must fail the check, got $RC"

# An UNIMPORTABLE package is its own verdict, not a silent pass: if the venv
# cannot say where the code is, nothing here can claim it is current.
cat >"$T/venv/bin/python" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/venv/bin/python"
run check
has "not found" "an unimportable package did not report so"
[ "$RC" = 1 ] || fail "an unimportable package must fail the check, got $RC"

# --- and the RUNNING daemon is checked against the installed code ---------
# THE LAYER ABOVE THE ONE ABOVE. The block above closed "installed versus
# package"; a long-lived process is a THIRD copy, and nothing compared it to
# either, so a daemon that was never restarted after an install passed every
# marker in this file while drawing last week's icon. Reported by a human, in
# exactly those words: "it did not restart the indicator, which I would expect
# it to".
#
# /proc/<pid>'s mtime IS the process start time on Linux, so this drives the
# real comparison with THIS TEST SHELL as the daemon: files stamped before it
# are code the process could have loaded, files stamped after it are not.
cat >"$T/venv/bin/python" <<EOF
#!/bin/sh
case "\$*" in
*mux_desktop_notifier*os.path.dirname*) echo "$SITE" ;;
esac
exit 0
EOF
chmod +x "$T/venv/bin/python"
for _f in "$HERE"/desktop-notifier/mux_desktop_notifier/*.py; do
  cp "$_f" "$SITE/"; done

if [ -d "/proc/$$" ]; then
  # NOT RUNNING is not stale: there is no process to be wrong about, and a
  # headless box with no graphical session is a healthy version of this.
  SCTL_PID=0 run check; unset SCTL_PID
  has "not running" "a stopped unit was not reported as such"
  case $OUT in
  *"RUNNING daemon started BEFORE"*) fail "a unit that is not running was
called stale; there is no process there to be stale" ;;
  esac

  # Code the daemon could have loaded: everything predates it.
  find "$SITE" -name '*.py' -exec touch -t 197001020000 {} +
  SCTL_PID=$$ run check; unset SCTL_PID
  has "running daemon is on the installed code" \
    "code older than the process was called stale"

  # ... and now an install lands UNDER a daemon that is still running: the
  # file is newer than the process, so the process cannot be running it.
  touch "$SITE/render.py"
  SCTL_PID=$$ run check; unset SCTL_PID
  has "RUNNING daemon started BEFORE" \
    "a daemon older than its own code was not reported"
  has "render.py" "the stale-process report did not name the file"
  [ "$RC" = 1 ] || fail "a daemon running code it predates must fail the
check, got $RC. Passing is what stops a provisioner ever restarting it."
  has "setup.sh service" "the stale-process report named no remedy"
fi
rm -rf "$T/site"

# --- THE VENV FOLDED INTO MUX'S PAYLOAD ----------------------------------
# `~/.venvs/mux-desktop-notifier` became `~/.local/share/mux/venv` (fleet
# install-placement rule, 2026-10-01): `~/.venvs` had the same ours-only
# smell as the `~/.local/libexec` that ruling struck, a root at the top of
# $HOME with ten tenants and nobody else's.
#
# HOME IS PINNED FOR THESE, which the rest of this file does not do. The
# retired path is $HOME-relative, so with the real home these cases would
# report on the DEVELOPER's own venv: a test that measures the machine it
# runs on rather than the code, which is the trap test/setup.t records
# against itself. Caught here the same way, by the suite going red on a box
# that happens to still have one.
_vh=$T/vhome
mkdir -p "$_vh/.local/share"
_vrun() {   # <verb...>: the installer with HOME and XDG pinned
  env PATH="$T/bin" HOME="$_vh" XDG_CONFIG_HOME="$T/xdg" \
    XDG_DATA_HOME="$_vh/.local/share" MUX_DESKTOP_NOTIFIER_BIN="$T/bin" \
    SCTL="$SCTL" SCTL_ENABLED=disabled SCTL_PID=0 \
    "$SETUP" "$@" 2>&1 || true
}

# THE DEFAULT LANDS INSIDE THE PAYLOAD, derived from XDG_DATA_HOME rather
# than hardcoded, so a box that moves its data home takes the venv with it.
_vo=$(_vrun check)
case $_vo in
*"$_vh/.local/share/mux/venv"*) ;;
*) fail "the default venv is not inside mux's payload, so the package is
still spread over two roots: [$_vo]" ;;
esac
case $_vo in
*'.venvs'*) fail "the old \$HOME/.venvs path is still the default: [$_vo]" ;;
esac

# A SURVIVING OLD VENV IS REPORTED, because install only removes it after a
# successful rebuild, so a box that has not re-run install yet has two.
mkdir -p "$_vh/.venvs/mux-desktop-notifier"
_vo=$(_vrun check)
case $_vo in
*'retired venv survives'*) ;;
*) fail "a leftover $_vh/.venvs/mux-desktop-notifier was not reported,
so it sits
there unnoticed as a second copy nothing resolves through: [$_vo]" ;;
esac

# AND A SCRATCH-PREFIX RUN MUST NOT RETIRE A LIVE VENV, which is the gotcha
# `_place-conversion.md` records because bt-sane's conversion did exactly this
# to itself, mid-verification, on 2026-10-01: `OLD_VENV` ignores PREFIX (the
# old path never had one), so a verification run that builds a venv in a
# throwaway prefix satisfies the "new one works" check and then deletes the
# real `~/.venvs/<pkg>` it has no business touching.
#
# THE GATE IS THE LITERAL REAL PATH, not `${XDG_DATA_HOME:-...}`, because a
# verification run overrides THAT too (the recipe's own step 1 does), so a
# comparison against the variable is no gate at all. Here HOME is pinned to
# the sandbox while XDG_DATA_HOME points somewhere else entirely, which is
# the shape of the run that caused the incident.
# DRIVEN THROUGH `app`, WHICH IS THE ONLY CALLER, and the first version of
# this case drove `check` instead: the retire never ran, so the assertion
# passed with the guard deleted. The corpus said SURVIVED, which is the one
# thing that tells a covering assertion from a decorative one.
#
# AND AGAINST A COPY of the installer, because `PKG_DIR` is derived from the
# script's own location and is not overridable, and `app` does
# `rm -rf "$PKG_DIR/build"`: run against the real file it would reach outside
# the sandbox this harness promises not to leave.
#
# THE VENV IS PRE-CREATED with a stub `pip`, so `app` skips `python3 -m venv`
# and makes no network call. That is not testing the stub: the venv BUILD is
# this file's documented gap, and what is under test here is the guard that
# runs AFTER it.
mkdir -p "$T/pkg" "$_vh/.venvs/mux-desktop-notifier" "$T/scratch/mux/venv/bin"
cp "$SETUP" "$T/pkg/setup.sh"
printf 'live\n' >"$_vh/.venvs/mux-desktop-notifier/marker"
for _f in pip mux-desktop-notifier; do
  printf '#!/bin/sh\n:\n' >"$T/scratch/mux/venv/bin/$_f"
  chmod +x "$T/scratch/mux/venv/bin/$_f"
done
# PATH KEEPS THE STUB FIRST AND THE REAL TOOLS AFTER. The curated
# `PATH="$T/bin"` the cases above use has no `mkdir` or `ln`, so `app` died
# on its first line and the `|| true` hid it: the control below is what
# caught that, which is the whole reason a control is here.
env PATH="$T/bin:$PATH" HOME="$_vh" XDG_CONFIG_HOME="$T/xdg" \
  XDG_DATA_HOME="$T/scratch" MUX_DESKTOP_NOTIFIER_BIN="$T/bin" \
  SCTL="$SCTL" SCTL_ENABLED=disabled SCTL_PID=0 \
  sh "$T/pkg/setup.sh" app >/dev/null 2>&1 || true
[ -f "$_vh/.venvs/mux-desktop-notifier/marker" ] \
  || fail "a run against a scratch XDG_DATA_HOME deleted the LIVE venv at
$_vh/.venvs/mux-desktop-notifier. That is bt-sane's incident, in the
# function this
package shares the shape with."

# AND THE CONTROL: with the venv at its REAL path the retire DOES fire, or
# the assertion above would hold for a gate that never lets anything through.
mkdir -p "$_vh/.local/share/mux/venv/bin"
for _f in pip mux-desktop-notifier; do
  printf '#!/bin/sh\n:\n' >"$_vh/.local/share/mux/venv/bin/$_f"
  chmod +x "$_vh/.local/share/mux/venv/bin/$_f"
done
env PATH="$T/bin:$PATH" HOME="$_vh" XDG_CONFIG_HOME="$T/xdg" \
  XDG_DATA_HOME="$_vh/.local/share" MUX_DESKTOP_NOTIFIER_BIN="$T/bin" \
  SCTL="$SCTL" SCTL_ENABLED=disabled SCTL_PID=0 \
  sh "$T/pkg/setup.sh" app >/dev/null 2>&1 || true
[ ! -d "$_vh/.venvs/mux-desktop-notifier" ] \
  || fail "control: at the REAL payload path the old venv was NOT retired, so
the gate refuses everything and the assertion above proves nothing"

# ... AND SAYING SO IS NOT AN [OK]. A marker that announces its own existence
# on every clean box is noise, and it broke this file's own premise that
# nothing should read [OK] when nothing is installed.
rm -rf "$_vh/.venvs"
_vo=$(_vrun check)
case $_vo in
*'retired venv'*) fail "with no leftover, the check still talks about one:
[$_vo]" ;;
esac

# --- THE RENAME RETIRES THE PREVIOUS NAME ---------------------------------
# This package was `mux-indicator` until 2026-10-04, and A RENAME IS A MODE
# SWITCH: this fleet's install-placement rule says one must REMOVE what it
# replaces. The failure if it does not is not cosmetic and not transient. The
# old unit is ENABLED and points at a console script `pip install` of the
# renamed project deletes, so the user manager fails it at EVERY LOGIN, for
# ever, and this file's own uninstall path already argues that a dangling unit
# is worse than one that is gone.
#
# DRIVEN THROUGH `service`, which is where the retirement lives, and that
# placement is the point: `app` is the one function this file documents as
# untestable (a network, minutes, and stubbing pip would be testing the stub),
# so a retirement living there would be a seam nothing ever executes. This
# package has shipped exactly that twice (both latch hooks, all four
# envhooks), so it is worth a sentence rather than a shrug.
mkdir -p "$T/xdg/systemd/user" "$T/bin" "$T/state/mux" "$T/venv/bin"
printf '#!/bin/sh
exit 0
' >"$T/venv/bin/pip"; chmod +x "$T/venv/bin/pip"
: >"$T/venv/bin/mux-desktop-notifier"
chmod +x "$T/venv/bin/mux-desktop-notifier"
printf '[Unit]
' >"$T/xdg/systemd/user/mux-indicator.service"
ln -sfn "$T/venv/bin/mux-indicator" "$T/bin/mux-indicator"
printf 'northwood 2
' >"$T/state/mux/indicator-slots"
run service
[ ! -e "$T/xdg/systemd/user/mux-indicator.service" ] \
  || fail "the previous name's unit survived the rename: it is ENABLED and
points at a console script pip has deleted, so the user manager fails it at
every login from now on"
# `-L` AND `-e`, NOT `-e` ALONE, and the mutation is what found it: this
# link points into the venv at a console script pip has deleted, so it is
# DANGLING, and `-e` follows a symlink and answers false for a dangling one.
# The assertion therefore passed whether or not the link had been removed,
# about the one case it exists for. A vacuous assertion reads as coverage.
[ ! -L "$T/bin/mux-indicator" ] && [ ! -e "$T/bin/mux-indicator" ] \
  || fail "the previous name's command survived as a dangling symlink on
PATH, which is what makes it worse than a stale one: it fails rather than
doing the wrong thing, and nothing says why"
has 'retired the mux-indicator unit' "a retirement must SAY so: this runs
once, during an upgrade nobody is watching, and an unexplained disappearance
is indistinguishable from the install having broken something"

# AND THE COLOUR SLOTS ARE CARRIED OVER, NOT ABANDONED, because they are
# state the package WRITES and cannot rebuild: the file holds which colour
# each host was assigned and the order that produced it is gone. Doing it in
# the INSTALLER is the rule this repo paid for once, when a migration done
# lazily by a reader took a snapshot and froze a live record for an hour.
[ -f "$T/state/mux/desktop-notifier-slots" ] || fail "the colour slots were
not carried over, so every host silently changes colour on upgrade"
[ ! -e "$T/state/mux/indicator-slots" ] || fail "the old slots file was left
behind, so the next release cannot tell a migration from a fresh install"

# AND IT NEVER CLOBBERS AN ALREADY-MIGRATED FILE, which is the half an
# idempotent installer needs: `service` runs on every install, so a second
# pass must not overwrite the live slots with a stale leftover. Asserted with
# BOTH present, which is the only state in which the question can be answered.
printf 'old\n' >"$T/state/mux/indicator-slots"
printf 'live\n' >"$T/state/mux/desktop-notifier-slots"
run service
[ "$(cat "$T/state/mux/desktop-notifier-slots")" = live ] || fail "a re-run
overwrote the live colour slots with the stale pre-rename file"

pass
