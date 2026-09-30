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
#   MUX_INDICATOR_VENV   venv dir   (default ~/.venvs/mux-indicator)
#   MUX_INDICATOR_BIN    bin dir    (default ~/.local/bin)
set -eu

self=$0
case $self in */*) ;; *) self=$(command -v -- "$self" || echo "$self") ;; esac
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)

VENV=${MUX_INDICATOR_VENV:-$HOME/.venvs/mux-indicator}
BIN_DIR=${MUX_INDICATOR_BIN:-$HOME/.local/bin}
UNIT=mux-indicator.service
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

app() {
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

# check: the [OK]/[FAIL] MARKER contract (same as `mux check`): coloured ONLY
# on a real terminal, so a caller that captures the output repaints the plain
# markers itself. mux owns this copy; no integrator dependency.
check() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _e=$(printf '\033')
    _G="$_e[1;32m"; _R="$_e[1;31m"; _O="$_e[0m"
  else
    _G=; _R=; _O=
  fi
  RC=0
  ok()  { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$*"; }
  bad() { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$*"; RC=1; }

  if [ -x "$VENV/bin/mux-indicator" ]; then ok "venv app ($VENV)"
  else bad "venv app missing ($VENV); run: install app"; fi
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
