#!/bin/sh
# setup.sh - set up mux-indicator (the SNI tray icon for mux agent-session
# state) for the CURRENT user. Standalone: just run `./setup.sh`. This script is
# the single source of the install procedure; an integrator (a provisioning
# system) can delegate to it by calling `setup.sh install` / `setup.sh check`,
# so the steps are identical whether or not one drives it, and pipx-vs-venv
# stays an internal detail.
#
#   setup.sh install     build the app env + install & enable the service
#   setup.sh app         just the app: an isolated venv + a ~/.local/bin script
#   setup.sh service     just the systemd --user unit (install + enable + start)
#   setup.sh check       verify the install ([OK]/[FAIL]/[WARN] markers)
#   setup.sh uninstall   remove the unit + the ~/.local/bin script
#
# All userspace: NO sudo. Idempotent (safe to re-run; adopts what exists). Needs
# python3 (for the venv) and, for the service, a systemd --user manager. A tray
# HOST (waybar's tray, or any desktop's) and `mux` on PATH are runtime needs.
# Overrides:
#   MUX_INDICATOR_VENV   venv dir   (default ~/.local/share/mux/venv)
#   MUX_INDICATOR_BIN    bin dir    (default ~/.local/bin)
set -eu

self=$0
case $self in */*) ;; *) self=$(command -v -- "$self" || echo "$self") ;; esac
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)

# THE VENV LIVES INSIDE MUX'S PAYLOAD, per the fleet install-placement rule
# (ruled 2026-10-01). It was `~/.venvs/mux-indicator`, and `~/.venvs` had the
# same ours-only smell as the `~/.local/libexec` that ruling struck: a root at
# the top of $HOME with ten tenants, none of them anybody else's. One payload
# tree per package is the durable reason, and it is what makes uninstall and
# audit a single question rather than two.
#
# THE XDG DATA HOME, NOT A SELF-LOCATED PATH, which is the one place this file
# differs from mux's core on purpose: this script is run standalone as often
# as through `mux`, so it cannot assume it sits beside an installed payload.
# A venv is also not reachable by self-location in any case, since its
# shebangs are absolute.
_mux_pay=${XDG_DATA_HOME:-$HOME/.local/share}/mux
VENV=${MUX_INDICATOR_VENV:-$_mux_pay/venv}
# WHERE IT USED TO BE, named so install can retire it and check can report it
# rather than each spelling the old path again.
OLD_VENV=$HOME/.venvs/mux-indicator
BIN_DIR=${MUX_INDICATOR_BIN:-$HOME/.local/bin}
UNIT=mux-indicator.service
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

# _retire_old_venv: A REBUILD, NOT A MOVE, and the distinction is the whole
# reason this is safe. A venv bakes an ABSOLUTE interpreter path into every
# console script and into pyvenv.cfg, so moving the directory leaves every
# entry point pointing at a python that is no longer there. The new venv is
# built from scratch at the new path by `app` below, and only then is the old
# one removed.
#
# REMOVED ONLY ON SUCCESS, which is why this runs AFTER the build rather than
# before: a failed rebuild that had already deleted the old venv would leave
# the box with no indicator at all, and the daemon it was running would be
# the last copy.
_retire_old_venv() {
  [ -d "$OLD_VENV" ] || return 0
  [ -x "$VENV/bin/mux-indicator" ] || return 0
  case $OLD_VENV in
  "$HOME"/.venvs/?*) ;;
  *) return 0 ;;
  esac
  # AND THE NEW VENV MUST BE THE REAL ONE, not a scratch prefix's. `OLD_VENV`
  # ignores PREFIX because the old path never had one, so a verification run
  # against a throwaway prefix would build a venv there, satisfy the check
  # above, and then delete the LIVE venv it has no business touching. That is
  # not hypothetical: it is what bt-sane's conversion did to itself on
  # 2026-10-01, mid-verification, and `_place-conversion.md` records it as a
  # gotcha for exactly this function in every venv package.
  # THE LITERAL REAL PATH, not `${XDG_DATA_HOME:-...}`, which was the first
  # version and was no gate at all: a verification run overrides XDG_DATA_HOME
  # too (the recipe's own step 1 does), so the comparison would hold against a
  # throwaway prefix and delete the live venv anyway.
  #
  # THE COST IS THE SAFE ONE: somebody whose XDG_DATA_HOME genuinely points
  # elsewhere never gets the retire, and keeps a stale directory that nothing
  # reads. Deleting a live venv is the other kind of wrong.
  case $VENV in
  "$HOME"/.local/share/mux/venv) ;;
  *) return 0 ;;
  esac
  rm -rf -- "$OLD_VENV"
  rmdir "$HOME/.venvs" 2>/dev/null || :
  echo "mux-indicator: retired the old venv at $OLD_VENV"
}

app() {
  mkdir -p "$(dirname "$VENV")"
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  # Deps come from the package's pyproject.toml (the single source): the first
  # install resolves them; the forced --no-deps reinstall then guarantees a
  # code change is picked up on a re-run (same version would else no-op).
  "$VENV/bin/pip" install -q "$PKG_DIR"
  "$VENV/bin/pip" install -q --force-reinstall --no-deps "$PKG_DIR"
  rm -rf "$PKG_DIR/build" "$PKG_DIR"/*.egg-info    # in-place build detritus
  mkdir -p "$BIN_DIR"
  ln -sfn "$VENV/bin/mux-indicator" "$BIN_DIR/mux-indicator"
  echo "mux-indicator: app -> $BIN_DIR/mux-indicator"
  _retire_old_venv
}

service() {
  mkdir -p "$UNIT_DIR"
  install -m 0644 "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "$UNIT" 2>/dev/null || true
  # RESTART, not `enable --now`: a re-run has to pick up a unit OR a code
  # change, and `--now` only starts something that is not already running.
  #
  # AND IT SAYS WHICH OF THE THREE HAPPENED, which it did not before. This
  # printed "installed + enabled" unconditionally, so the RESTART (the one
  # action anybody is watching for after a code change) was invisible, and
  # a restart that FAILED printed the same sentence as one that worked.
  # Reported from a real run: the daemon had in fact been restarted onto the
  # new code, and the only evidence on screen said it had not been.
  #
  # A message that cannot distinguish success from failure is the same bug
  # as a presence check that cannot distinguish installed from working, one
  # layer out, and this package already has that rule written down.
  _svc_err=$(systemctl --user restart "$UNIT" 2>&1) && {
    echo "mux-indicator: service $UNIT installed, enabled, RESTARTED"
    return 0; }
  # NO USER MANAGER IS NOT A FAILURE. A headless or pre-login install
  # legitimately cannot start anything, the unit is enabled, and it comes up
  # at the next login. That is the third answer, and it is why this was
  # wrapped in `|| true` in the first place: the mistake was letting that
  # one real case silence every other one too.
  case $_svc_err in
  *"Failed to connect to"*|*"not been booted"*|*"No such file or dir"*)
    echo "mux-indicator: service $UNIT installed + enabled; no user" \
      "manager here, so it starts at the next login"
    return 0 ;;
  esac
  echo "mux-indicator: service $UNIT installed + enabled, but the" \
    "RESTART FAILED, and it is still running the OLD code:" >&2
  printf '%s\n' "$_svc_err" | sed 's/^/mux-indicator:   /' >&2
  return 1
}

uninstall() {
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT" "$BIN_DIR/mux-indicator"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "mux-indicator: uninstalled (venv $VENV left in place)"
  echo "mux-indicator: it sits inside mux's payload, so \`mux\`'s own"
  echo "mux-indicator:   uninstall removes it along with everything else."
}

# _code_current: is the INSTALLED code the package's code?
#
# THE CHECK THAT WAS MISSING, and its absence was not theoretical: northwood ran
# a copy installed on 2026-08-30 for weeks while every marker here read [OK].
# Everything existed, the unit matched, the service was enabled, and because a
# provisioner runs `apply` only when `check` FAILS, passing is exactly what kept
# the stale code alive. A green check was the thing preventing the fix.
#
# That is this package's own rule turned on itself: `mux check` exists because a
# presence check says [OK] to a box that is fully installed and fully broken,
# which is worse than failing because it sends you to look elsewhere.
#
# BY CONTENT, NOT BY VERSION. A version-keyed check needs someone to remember to
# bump it, and the same fleet has already watched a version-keyed plugin cache
# sit stale through two full provisions for exactly that reason. Content cannot
# be forgotten.
#
# The interpreter is ASKED where the package landed rather than globbing a
# python version out of the venv path: one less thing to break when the
# interpreter moves.
# THE PROBE RUNS FROM `/`, WHICH IS LOAD-BEARING. Python puts the current
# directory FIRST on sys.path for `python -c`, so running this check from inside
# the package tree imports the SOURCE copy, and the comparison below then holds
# each file against ITSELF and passes no matter how stale the venv is. That is
# the very tautology this function exists to destroy, and it is worst in the
# case it is most used: `./setup.sh check` in a checkout, while iterating on the
# code, is exactly when a false [OK] costs the most.
#
# `cd /` rather than `-P` or PYTHONSAFEPATH, which are 3.11+; this package
# supports 3.8.
_installed_dir() {
  (cd / && "$VENV/bin/python" -c \
    'import mux_indicator,os;print(os.path.dirname(mux_indicator.__file__))' \
    2>/dev/null) || true
}

_code_current() {
  _cc_dir=$(_installed_dir)
  if [ -z "$_cc_dir" ] || [ ! -d "$_cc_dir" ]; then
    bad "installed code not found (the venv cannot import it)"
    return 0
  fi
  # AND REFUSE A SELF-COMPARISON OUTRIGHT, which covers every OTHER way the
  # two paths can converge: an editable install, a symlinked site-packages,
  # a future change to where the venv lives. Fixing only the cwd would leave a
  # check that is correct today and silently vacuous the next time something
  # moves. A comparison with no two sides cannot answer the question, so it
  # says so instead of reporting agreement.
  if [ "$_cc_dir" = "$PKG_DIR/mux_indicator" ]; then
    bad "the venv imports the SOURCE tree ($_cc_dir)"
    bad "  nothing here can be stale or current; this check is vacuous"
    return 0
  fi
  _cc_drift=
  for _cc_f in "$PKG_DIR"/mux_indicator/*.py; do
    [ -f "$_cc_f" ] || continue
    _cc_b=${_cc_f##*/}
    cmp -s "$_cc_f" "$_cc_dir/$_cc_b" 2>/dev/null \
      || _cc_drift="$_cc_drift $_cc_b"
  done
  if [ -n "$_cc_drift" ]; then
    bad "installed code is STALE or missing:$_cc_drift"
    bad "  run: setup.sh indicator install   (then the service restarts)"
  else
    ok "installed code matches the package"
  fi
}

# _running_current: is the RUNNING daemon on the code that is INSTALLED?
#
# THE LAYER THIS FILE'S OWN CHECK WAS MISSING. _code_current closed "installed
# versus package"; a long-lived process is a THIRD copy and nothing compared it
# to either, so a daemon that was never restarted after an install passed every
# marker here (venv current, unit matching, service enabled), while drawing
# last week's icon. That is precisely the bug this file was written to fix, one
# layer out, and it was found the way the first one was: by a human saying "it
# did not restart, and I would expect it to".
#
# The same trap the agent-plugin notes already record: both copies being
# present on disk proves nothing whatever about what a live process is running.
#
# MTIME OF /proc/<pid> IS THE PROCESS START TIME on Linux, so `-nt` answers this
# with no date arithmetic and no systemd timestamp format to keep tracking.
_running_current() {
  # THE INSTALLED CODE FIRST, and silently when there is none: with nothing
  # installed there is nothing for a process to be stale against, and
  # _code_current has already said so. Saying it twice would make one
  # problem look like two, and on an empty prefix it would put an [OK] on a
  # box where nothing whatever is installed.
  _rn_dir=$(_installed_dir)
  [ -n "$_rn_dir" ] && [ -d "$_rn_dir" ] || return 0
  _rn_pid=$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null \
    || true)
  case ${_rn_pid:-0} in
  ''|0|*[!0-9]*)
    # NOT RUNNING IS NOT STALE: there is no process to be wrong about.
    # Whether it OUGHT to be running is the `enabled` marker's question,
    # and a headless box with no graphical session is a healthy version
    # of this. Reported rather than passed over, the same way `mux check`
    # reports the checks it skips for want of a server.
    ok "$UNIT is not running (nothing to be stale)"
    return 0 ;;
  esac
  if [ ! -d "/proc/$_rn_pid" ]; then
    ok "$UNIT: cannot see pid $_rn_pid (no /proc here)"
    return 0
  fi
  _rn_stale=
  for _rn_f in "$_rn_dir"/*.py; do
    [ -f "$_rn_f" ] || continue
    # shellcheck disable=SC3013  # -nt is not POSIX; see below
    # `-nt` IS A REAL PORTABILITY NOTE AND IS KEPT ON PURPOSE, which is why this
    # is disabled here rather than in .shellcheckrc: a second, accidental use
    # somewhere portable must still fail. dash and bash both implement it, and
    # this line is already Linux-only by construction because it compares
    # against `/proc/<pid>`, whose mtime IS the process start time. The portable
    # alternative is date arithmetic on two `stat` formats that differ between
    # GNU and BSD, which is more code and more to get wrong for no gain here.
    [ "$_rn_f" -nt "/proc/$_rn_pid" ] || continue
    _rn_stale="$_rn_stale ${_rn_f##*/}"
  done
  if [ -n "$_rn_stale" ]; then
    bad "the RUNNING daemon started BEFORE this code:$_rn_stale"
    bad "  it is still drawing the old icon; run: setup.sh service"
  else
    ok "the running daemon is on the installed code"
  fi
}

# check: the [OK]/[FAIL]/[WARN] MARKER contract (same as `mux check`):
# coloured ONLY on a real terminal, so a caller that captures the output
# repaints the plain markers itself. mux owns this copy; no integrator
# dependency.
#
# WARN WAS MISSING UNTIL NOW, while this file's own usage text has promised
# `[OK]/[FAIL]/[WARN]` since it was written: the first WARN anybody tried to
# emit died with `warn: not found`, caught by the test for it on the first
# run. Worth recording because the file documented a three-marker contract
# and implemented two, which is the same shape as a flag that parses and does
# nothing.
check() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _e=$(printf '\033')
    _G="$_e[1;32m"; _R="$_e[1;31m"; _Y="$_e[1;33m"; _O="$_e[0m"
  else
    _G=; _R=; _Y=; _O=
  fi
  RC=0
  ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$*"; }
  bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$*"; RC=1; }
  # ADVISORY, so it does NOT set RC: a leftover is not a broken install, and
  # a provisioner gating on the exit code must not be made to loop over one.
  warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$*"; }

  if [ -x "$VENV/bin/mux-indicator" ]; then ok "venv app ($VENV)"
  else bad "venv app missing ($VENV); run: install app"; fi
  # A RETIRED VENV THAT SURVIVED. A WARN, not a FAIL: nothing resolves
  # through it once the bin link points at the new one, so it is wasted disk
  # and a confusing second copy rather than a broken install. `install`
  # removes it, but only after a successful rebuild, so a box that has not
  # re-run install yet is correctly reported rather than failed.
  # SILENT WHEN THERE IS NOTHING TO SAY, not an [OK]: this reports a LEFTOVER,
  # and a marker that announces its own existence on every clean box is noise
  # (and broke this file's "nothing is installed, so nothing should read [OK]"
  # premise, which is a fair premise). Same call the unaddressable-session
  # marker in mux check makes.
  [ -d "$OLD_VENV" ] \
    && warn "retired venv survives: $OLD_VENV (install removes it)" || :
  if "$VENV/bin/python" -c 'import dbus_next, PIL' 2>/dev/null
  then ok "deps import (dbus-next, Pillow)"
  else bad "deps not importable in the venv"; fi
  if [ -x "$BIN_DIR/mux-indicator" ]; then ok "$BIN_DIR/mux-indicator"
  else bad "$BIN_DIR/mux-indicator missing"; fi
  if cmp -s "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT" 2>/dev/null
  then ok "$UNIT current"; else bad "$UNIT missing or stale"; fi
  _code_current
  _running_current
  _st=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)
  if [ "$_st" = enabled ]; then ok "$UNIT enabled"
  else bad "$UNIT not enabled (${_st:-unknown})"; fi
  return "$RC"
}

case "${1:-install}" in
  install)   app; service ;;
  app)       app ;;
  service)   service ;;
  check)     check ;;
  uninstall) uninstall ;;
  *) echo "usage: setup.sh [install|app|service|check|uninstall]" >&2
     exit 2 ;;
esac
