#!/bin/sh
# setup.sh - install / uninstall / check / test the mux package into a prefix.
# The SINGLE entry point a consumer uses (a person, or a provisioning layer):
# mux owns its own layout, so nothing outside needs to know where bin, libexec,
# share, and man live. The runtime command stays `mux` (bin/mux); this only
# wires it in and audits it.
#
#   ./setup.sh install     link core bin + libexec + share + man (NO indicator)
#   ./setup.sh uninstall   remove those links
#   ./setup.sh check       audit install + deps; [OK]/[FAIL] markers; drift rc
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#   ./setup.sh all         install + the optional tray indicator
#   ./setup.sh indicator [VERB]  drive the optional indicator sub-package (a
#                          passthrough to indicator/setup.sh; VERB defaults to
#                          install). Kept OUT of `install`: it is Python + a
#                          daemon, unlike core mux (shell, no deps but tmux).
#
# POSIX sh, non-privileged. PREFIX (default ~/.local) and the XDG_* vars
# override the destinations, so a test drives it against a scratch dir. The
# <pkg> namespace lives in the INSTALL prefix (~/.local/libexec/mux), applied
# here; the source tree carries none (libexec/, share/), as a package should.
set -eu

PKG=mux
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_lib=$PREFIX/libexec
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
RC=0

# marker contract: plain [OK]/[FAIL]/[WARN] a host styles; coloured at a tty,
# plain when piped or under NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[1;32m'); _R=$(printf '\033[1;31m')
  _Y=$(printf '\033[1;33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_ln()  { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; }
_rmln() { [ "$(readlink "$2" 2>/dev/null)" = "$1" ] && rm -f "$2" || :; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

do_install() {
  mkdir -p "$_bin" "$_lib" "$_shr"
  for _t in "$_root"/bin/*; do _ln "$_t" "$_bin/$(basename "$_t")"; done
  _ln "$_root/libexec" "$_lib/$PKG"      # ~/.local/libexec/mux -> clone/libexec
  _ln "$_root/share"   "$_shr/$PKG"      # ~/.local/share/mux   -> clone/share
  _man_pages | while IFS= read -r _m; do
    _ln "$_m" "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")"; done
  echo "$PKG: linked into $PREFIX (bin, libexec/$PKG, share/$PKG, man)"
  _reload_live
  _tmux_conf_notice
  _indicator_notice
}

# The conventional tmux.conf locations, one per line. Factored because two
# callers below ask DIFFERENT questions of the same list, and the list itself is
# the part that would drift.
_tmux_confs() {
  for _c in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" \
      "$HOME/.tmux.conf"; do
    [ -r "$_c" ] && printf '%s\n' "$_c"; done
}
# A HERE-DOC, NOT A PIPELINE, and the first version got this wrong in the
# direction that suppresses a warning: a `while` loop fed by a pipe runs in a
# SUBSHELL, so a `return` inside it cannot answer for this function, and a
# loop that runs ZERO times (no tmux.conf at all, which is every fresh box)
# exits 0, i.e. "found". The notice then never fired for the one user who needs
# it. Caught by test/setup.t on the first run.
_conf_mentions() {   # PATTERN -> 0 if any tmux.conf contains it
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    grep -q -- "$1" "$_c" 2>/dev/null && return 0
  done <<EOF
$(_tmux_confs)
EOF
  return 1
}

# INSTALLING A FILE DOES NOT RELOAD A RUNNING SERVER, which is this package's
# most expensive recurring bug rather than a detail. A live tmux keeps the
# bindings, hooks and status format it read at START, so every new binding is
# inert on the machine that just received it: `mux undo-pane` was unreachable on
# both boxes for two releases that way, and `prefix ?` repeated it in 0.77. The
# only thing that fixes it is `mux reload`, so the install does it rather than
# leaving a correct install that behaves like a broken one.
#
# IT ALSO CLOSES A PROVISIONER'S LOOP. A provisioner runs `apply` only when
# `check` FAILS, and mux's check now correctly FAILS on a stale server, so
# without this the drift is reported forever by a pin whose install already
# ran ("APPLY DID NOT FIX", observed 2026-09-29). Prevention belongs here,
# in the step that made the file new.
#
# NOT THE SAME CALL AS THE TWO NOTICES BELOW, and the line between them is
# ownership rather than caution. A tmux.conf is the user's own FILE and an
# installer must not write it; the indicator is a separate PACKAGE whose stale
# code a restart could not fix anyway. A reload is neither: it is idempotent, it
# is the verb mux ships for exactly this, and the state it refreshes is mux's
# own.
#
# GUARDED ON THE LIVE CONFIG NAMING THIS INSTALL, which is what keeps it honest:
# if nothing sources THIS prefix's fragment then these servers are not running
# this install and reloading them would push an unrelated config, and in a
# test sandbox it would reach the developer's real server. `mux reload` itself
# never STARTS a server and says so when there was nothing up.
# A TILDE IS THE FORM PEOPLE ACTUALLY WRITE, and checking only the expanded
# path made this whole function inert on the one box it was written for: the
# real config says `source-file ~/.local/share/mux/mux.tmux`, tmux expands the
# `~` itself, and a textual guard looking for `/home/<user>/...` never matched.
# Correct-looking, silent, and wrong: the same shape as the bug above it.
_reload_live() {
  command -v tmux >/dev/null 2>&1 || return 0
  # Each form on its own LINE, so the corpus can mutate either: an anchor that
  # ends in a continuation backslash is failure mode two in test/mutants' own
  # header and never matches.
  _rf=$_shr/$PKG/mux.tmux
  _rt="~${_shr#"$HOME"}/$PKG/mux.tmux"
  _conf_mentions "$_rf" || _conf_mentions "$_rt" || return 0
  _out=$("$_bin/$PKG" reload 2>&1) || {
    echo "$PKG: NOTE could not reload live tmux servers: $_out" >&2
    echo "$PKG:      a running server keeps the bindings and hooks it read" >&2
    echo "$PKG:      at start, so run \`mux reload\` once that is fixed." >&2
    return 0; }
  case $_out in
  *'no running servers'*) return 0 ;;
  *) echo "$PKG: ${_out#mux: }" ;;
  esac
}

# THE SECOND STEP EVERY NEW USER HAS TO BE TOLD ABOUT. Linking mux into PATH
# does nothing visible: the status bar, the bindings and the strip all come from
# `source-file .../mux.tmux` in the user's own tmux.conf, and until that line
# exists mux looks installed and inert. That is the same "fully installed and
# fully broken" state `mux check` exists to catch, met one step earlier.
#
# IT SAYS RATHER THAN EDITS, deliberately, and this is the line where the
# install-placement rule bites: a tmux.conf is the user's own file, not a
# package input. mux writes `mux setup claude` into an agent's config because
# that verb's whole PURPOSE is that step and it asks first; an installer editing
# your tmux.conf as a side effect of `install` is a different thing, and the one
# irreversible mistake available here.
#
# SILENT WHEN THE LINE IS ALREADY THERE, so a re-install is quiet and this
# cannot become noise people learn to skip. The check is textual and looks in
# both conventional locations plus $XDG_CONFIG_HOME.
_tmux_conf_notice() {
  _frag=$_shr/$PKG/mux.tmux
  # ANY mux fragment, not this prefix's: a user who installed elsewhere has
  # already done this step, and nagging them would be wrong. The reload above
  # asks the narrower question on purpose.
  _conf_mentions "$PKG/mux.tmux" && return 0
  echo "$PKG: NOTE nothing sources mux's tmux fragment yet, so the status" >&2
  echo "$PKG:      bar, the agent strip and the key bindings will not" >&2
  echo "$PKG:      appear. Add this to your tmux.conf and reload tmux:" >&2
  echo "$PKG:" >&2
  echo "$PKG:        source-file $_frag" >&2
  echo "$PKG:        source-file $_shr/$PKG/mux-opinions.tmux   # optional" >&2
  echo "$PKG:" >&2
  echo "$PKG:      Then: mux setup claude   (wires your agent's hooks)" >&2
}

# AN INSTALLED INDICATOR IS A SECOND PACKAGE THAT TALKS TO THIS ONE, and core
# does not install, restart or own it. It is still worth SAYING when it has
# fallen out of step, because the coupling is a CONTRACT (`mux agent status`,
# JSON) and a skew there fails silently: a daemon built against an older
# contract keeps polling and simply publishes fewer items, which reads as "that
# partition is gone" rather than as a version problem.
#
# A NOTICE AND NOT A RESTART, deliberately. Restarting would not help: what is
# stale is the daemon's OWN code, not anything it caches from core, since it
# re-execs `mux` on every poll. And not an install either: that is a pip
# operation wanting a network, and keeping core free of that is the whole reason
# the indicator is a separate package.
#
# CONTENT, NOT VERSION: it asks the indicator's own check, which compares the
# package to what is installed and what is RUNNING. Never fatal, and silent
# when no indicator is installed: an optional sub-package must not make the
# core install noisy for everyone who does not use it.
_indicator_notice() {
  [ -e "$_bin/mux-indicator" ] || return 0
  sh "$_root/indicator/setup.sh" check >/dev/null 2>&1 && return 0
  echo "$PKG: NOTE the installed tray indicator differs from this package" >&2
  echo "$PKG:      (or its daemon is running older code). It polls a mux" >&2
  echo "$PKG:      contract, so leaving it behind loses items silently." >&2
  echo "$PKG:      Refresh it with: ./setup.sh indicator" >&2
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _rmln "$_t" "$_bin/$(basename "$_t")"; done
  _rmln "$_root/libexec" "$_lib/$PKG"
  _rmln "$_root/share" "$_shr/$PKG"
  _man_pages | while IFS= read -r _m; do
    _rmln "$_m" "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")"; done
  echo "$PKG: removed its links from $PREFIX"
}

do_check() {
  echo "== $PKG (package install) =="
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    [ "$(readlink "$_bin/$_n" 2>/dev/null)" = "$_t" ] \
      && ok "bin/$_n linked" || bad "bin/$_n not linked"; done
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec" ] \
    && ok "libexec/$PKG linked" || bad "libexec/$PKG not linked"
  [ "$(readlink "$_shr/$PKG" 2>/dev/null)" = "$_root/share" ] \
    && ok "share/$PKG linked" || bad "share/$PKG not linked"
  "$_root/bin/mux" check || RC=1      # deps + package data (its own markers)
}

_U="usage: setup.sh [install|uninstall|check|test|version|all|indicator]"
case "${1:-help}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null || true)
             echo "${_v:-$PKG (unversioned)}" ;;
  all)       do_install; sh "$_root/indicator/setup.sh" install ;;
  indicator) shift; exec sh "$_root/indicator/setup.sh" "$@" ;;  # passthrough
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
