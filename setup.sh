#!/bin/sh
# setup.sh - install / uninstall / check / test the mux package into a prefix.
# The SINGLE entry point a consumer uses (a person, or a provisioning layer):
# mux owns its own layout, so nothing outside needs to know where bin, libexec,
# share, and man live. The runtime command stays `mux` (bin/mux); this only
# wires it in and audits it.
#
#   ./setup.sh install     link core bin + libexec + share + man (NO notifier)
#   ./setup.sh uninstall   remove those links
#   ./setup.sh check       audit install + deps; [OK]/[FAIL] markers; drift rc
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#   ./setup.sh all         install + the optional desktop notifier
#   ./setup.sh <install|uninstall|check|paths> --system
#                          the MACHINE-WIDE mode, as root (below)
#   ./setup.sh desktop-notifier [VERB]   drive the optional notifier
#                          passthrough to desktop-notifier/setup.sh;
#                          VERB defaults to
#                          install). Kept OUT of `install`: it is Python + a
#                          daemon, unlike core mux (shell, no deps but tmux).
#
# POSIX sh, non-privileged. PREFIX (default ~/.local) and the XDG_* vars
# override the destinations, so a test drives it against a scratch dir. THEY
# ARE ENVIRONMENT VARIABLES AND NEVER ARGUMENTS: `PREFIX=/tmp/x sh setup.sh
# install`, not `sh setup.sh install PREFIX=/tmp/x`, which is refused rather
# than ignored (see the arity guard at the dispatch, and why it exists). The
# <pkg> namespace lives in the INSTALL prefix (~/.local/libexec/mux), applied
# here; the source tree carries none (libexec/, share/), as a package should.
#
# SYSTEM MODE (`--system`, as root) is the same payload, root-owned and closed
# (nothing writable by group or other), at /opt/mux, with the command at
# /usr/local/bin/mux and the man page under /usr/local/share/man: one tree
# plus its links, per the fleet's install-placement rule, and the same
# `--system` spelling drydock's root mode already calls. Every user then gets
# mux from one copy; their config, state and runtime stay per-user, because
# none of it was ever inside the payload. THE MODE SWITCH removes the sudo
# caller's user-mode copy in the same install, since two `mux` on PATH is
# banned and /usr/local/bin shadows ~/.local/bin. The desktop notifier stays
# per-user (a systemd --user unit and its venv), so it is not offered here
# and its venv survives the switch. DESTDIR stages the system tree under a
# root, as packagers expect; it grants nothing, since a non-root caller can
# only write where it already could.
set -eu

PKG=mux
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# The exit codes mux itself uses, so this installer refuses with the same
# vocabulary the package does.
[ -r "$_root/lib/mux-exit_lib" ] \
  || { echo "setup.sh: $_root/lib/mux-exit_lib missing" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_root/lib/mux-exit_lib"

_MODE=user
[ "${2:-}" = --system ] && _MODE=system
_dest=${DESTDIR:-}
if [ "$_MODE" = system ]; then
  case ${1:-} in
    install|uninstall)
      if [ -z "$_dest" ] && [ "$(id -u)" != 0 ]; then
        echo "setup.sh: --system installs as root" \
          "(sudo sh setup.sh $1 --system)" >&2
        exit "$MUX_EC_FAIL"
      fi ;;
  esac
  PREFIX=$_dest/usr/local
  _bin=$PREFIX/bin
  _shr=$_dest/opt
  _man=$PREFIX/share/man
else
  PREFIX=${PREFIX:-$HOME/.local}
  _bin=${XDG_BIN_HOME:-$PREFIX/bin}
  _shr=${XDG_DATA_HOME:-$PREFIX/share}
  _man=$_shr/man
fi
# Where the OTHER mode's command would be, so each mode can name a leftover.
_sysbin=$_dest/usr/local/bin/$PKG
# THE PAYLOAD: one tree holding mux as shipped, per the fleet's
# install-placement rule (ruled 2026-10-01). bin/, libexec/, share/ and man/
# live INSIDE it as siblings, because `bin/mux` resolves $0 and reads the
# other two relative to it; that invariant is what makes a checkout, a
# Homebrew keg and a relocated install all work, and it is why the nested
# `<payload>/share` stays. The wart is cosmetic; the invariant is not.
_pay=$_shr/$PKG
# WHERE THE PAYLOAD WILL BE WHEN IT RUNS, which differs from where it is
# WRITTEN only under DESTDIR: links carry the final path, as a staged
# package's must, or they dangle once the stage is installed.
_payt=${_pay#"$_dest"}
# THE RETIRED ROOT, kept as a name so install, uninstall and check all remove
# or report the same thing rather than each spelling it.
_oldlib=$PREFIX/libexec/$PKG
# No old layout ever lived under /usr/local, and retiring one there would
# rmdir a system directory that merely happened to be empty.
[ "$_MODE" = user ] || _oldlib=
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

# --- the install's notices reach the LOG as well as the terminal ----------
# BECAUSE ON THE FLEET'S PRIMARY INSTALL PATH NOBODY CAN READ THEM, measured
# 2026-10-01: a provisioner swallows this script's output entirely, so its log
# carried `install: pkg mux -> ~/.local` and not one of mux's own notices. The
# inert-fragment warning, the indicator skew and the agent-record adoption's
# repair advice all exist to be READ by a human, and on every provisioned box
# they went nowhere. That is this package's oldest rule one layer out: advice
# nobody can read is decoration.
#
# THE LOG RECORDS THE EVENT, THE TERMINAL EXPLAINS IT, so this is NOT a second
# copy of the prose waiting to drift from it. A notice is several lines of
# wrapped explanation; what belongs in a file capped at mutations-and-failures
# volume is ONE line naming the CONDITION. Reword the prose freely: the
# condition is the stable half, the same reason `_common.md` prescribes
# quoting a message's PREFIX rather than its wording.
#
# NOT EVERY NOTICE, and the test is whether the condition survives the install
# anywhere else. `mux check` already reports an unsourced fragment and absent
# scan roots durably, so those are covered the moment anybody looks. The
# adoption is not: it happens once, and afterwards nothing on the box can say
# it happened or that a record was kept unjudged.
#
# SOURCED, NEVER REQUIRED. setup.sh is otherwise standalone on purpose, since
# it is the one entry point a consumer or provisioner calls, so a missing lib
# costs the log line and never the install. That matches the lib's own stated
# bargain: a failed write must not break the thing being logged, and the
# reader is where the breakage surfaces.
_HAVE_LOG=
if [ -r "$_root/lib/mux-log_lib" ]; then
  # shellcheck source=/dev/null
  . "$_root/lib/mux-log_lib" && _HAVE_LOG=1
fi
_slog() { [ -n "$_HAVE_LOG" ] || return 0; mux_log setup "$@"; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

# --- a README in the CONFIG ROOT, naming every location -------------------
# WHY A FILE AND NOT A SYMLINK. The obvious convenience is a `logs ->
# ...state/mux` link inside the config dir, and it is wrong HERE even though
# inkscape keeps a log in its own config dir: $MUX_DIR is designed to be
# SHARED between machines (everything machine-local lives in the cache and
# state dirs, which is why sharing this one is the documented remedy for two
# boxes disagreeing). A link to machine-local state inside it either carries a
# session set and a log into a dotfiles repo, or DANGLES on the other box.
#
# SO THE ANSWER IS DOCUMENTATION, which a symlink cannot be: a README can SAY
# which roots are shared and which are per-machine, and a link cannot.
#
# IT NAMES THE DERIVATION, not only the resolved path, because a snapshot of
# an absolute path is advice that outlives its contract the first time a root
# moves. The variable and its default are the durable half; the resolved value
# is labelled as "here".
#
# IT NEVER CLOBBERS A FILE A HUMAN TOUCHED. Written when absent, refreshed
# only when it still carries the marker line mux wrote, and otherwise left
# exactly alone with a word said. Same care `mux setup claude` takes with
# somebody else's config, for the same reason: the failure that matters is not
# "the README is stale", it is "mux ate something I wrote".
_README_MARK='# Generated by mux setup.sh. Edits are kept: see the note below.'
_config_readme() {
  _cr_dir=${MUX_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mux}
  _cr_f=$_cr_dir/README
  if [ -e "$_cr_f" ] \
     && ! grep -qxF -- "$_README_MARK" "$_cr_f" 2>/dev/null; then
    echo "$PKG: left your own $_cr_f alone"
    return 0
  fi
  mkdir -p "$_cr_dir" 2>/dev/null || {
    echo "$PKG: could not write $_cr_f"; return 0; }
  cat >"$_cr_f" <<EOF || { echo "$PKG: could not write $_cr_f"; return 0; }
$_README_MARK

WHERE MUX KEEPS THINGS
======================

This directory is YOURS. mux reads it first and falls back to what it ships,
so a file here overrides the shipped one of the same name, and anything you
add is additive. An upgrade never touches it.

It is also meant to be SHAREABLE between machines: everything machine-local
lives under the state and cache roots below, so copying or symlinking this one
directory to another box is supported and is how two machines come to agree.

  THIS DIRECTORY        \$MUX_DIR
                        default \$XDG_CONFIG_HOME/mux, else ~/.config/mux
                        here: $_cr_dir
                        yours, shared between machines, upgrade-safe

  shipped defaults      \$MUX_SHARE
                        the installed payload's share/ directory
                        here: $_shr/$PKG
                        REPLACED ON UPGRADE: do not edit, override here instead

  durable state         \$MUX_STATE
                        default \$XDG_STATE_HOME/mux, else ~/.local/state/mux
                        the log, the session set, the indicator's colour slots
                        machine-local, survives a reboot, NOT shareable
                        the log's exact path: mux log --path

  rebuildable cache     \$MUX_CACHE
                        default \$XDG_CACHE_HOME/mux, else ~/.cache/mux
                        palette stamps and the discovery map
                        machine-local, safe to delete, mux rebuilds it

  per-boot runtime      \$XDG_RUNTIME_DIR
                        per-pane agent state, gone at reboot by design

  a send policy         /etc/mux/send-policy
                        root-owned, CONSULTED and never created by mux.
                        Absent means no grants, which is the closed default.

WHAT GOES IN HERE
=================

  config                one directive per line; only what OVERRIDES a default
                        EVERY knob it accepts, with its default and why you
                        would change it, is documented in
                          $_shr/$PKG/share/config.sample
                        Nothing needs configuring: mux's defaults live in its
                        CODE, so they hold on a box with no config at all.
                        That sample is all commented out on purpose. An ACTIVE
                        line restating a default is a second copy that can
                        drift, and one did: this config once set three latch
                        seams to what mux already used, got one of them
                        subtly wrong, and broke \`mux latch\` the day a
                        hook moved.
  partitions/           one <name>.partition per partition
  layouts/              saved layouts (mux save writes here)
  profiles              per-project settings, one row each
  profiles.d/           the heavier per-project form, <name>.profile
  hosts                 per-host colours, if you pin any
  themes/               colour themes, yours or overriding a shipped one
  agents/               agent profiles: what a pane's agent looks like
  envhooks.d/           your environment validators (see below)
  latch/                your own transport hooks, overriding the shipped ones
  desktop-notifier/     your focus and banner hooks, same (see below)

THE SHIPPED DEFAULTS ARE NOT MISSING
====================================

mux ships hooks and themes of its own. They are NOT copied here, because this
directory is yours and an upgrade must be able to replace a default without
touching your files. They live in the payload:

  $_pay/share/envhooks.d/        per session pointer mux can validate
  $_pay/share/latch/             per transport: auth, probe, classify
  $_pay/share/desktop-notifier/  focus/ for a click, toast/ for a banner
  $_pay/share/themes/            colour themes
  $_pay/share/agents/            agent profiles
  $_pay/share/layouts/           the layouts mux starts you with
  $_pay/share/partitions/        the baseline partition

To override one, put a file of the SAME NAME in the matching directory here;
to add one, use a name mux does not ship. No count is given above on purpose,
because a number here is a second copy of a fact that can drift: run
\`mux check\` to see what mux actually resolved, and \`ls\` those paths for
what is on offer.

A NOTE ON EDITS
===============

mux refreshes this file on install only while the first line above is intact.
Delete that line and this file becomes yours: mux will leave it alone and say
so, and you will stop getting updates to it.
EOF
  echo "$PKG: wrote $_cr_f (what each root holds, and which are shareable)"
}

# _payload_stage: build the new payload beside the live one and swap it in.
#
# IT COPIES, AND THAT IS THE POINT OF THE WHOLE CHANGE. Until now every root
# was a SYMLINK into the source clone, so an installed mux died the moment
# that clone moved: measured, with the source removed the entry point answers
# `No such file or directory` and nothing can diagnose it, because mux is the
# thing that is gone. A copy is self-contained, which is what Homebrew and
# the indicator's venv already were, so all three install paths now agree.
#
# STAGED AND SWAPPED, never emptied in place, because a live tmux calls
# `mux <verb>` on every status tick: removing the payload first would make
# every binding and the status bar fail for the length of a copy. Two renames
# is as close to atomic as a directory gets, which is the same reasoning that
# made the undo-pane record a rename rather than a create-then-fill.
_payload_stage() {
  _ps_new=$_pay.new
  _ps_old=$_pay.old
  # Expanded and CHECKED before anything is removed, per the standing rm
  # rule: this package's own harness once deleted this repository because an
  # empty value reached `rm -rf` at trap fire time.
  case $_pay in
    /*/*) ;;
    *) bad "refusing to stage a payload at '$_pay'"; return 1 ;;
  esac
  rm -rf -- "$_ps_new" "$_ps_old"
  mkdir -p "$_ps_new" || { bad "could not create $_ps_new"; return 1; }
  for _d in bin lib libexec share man; do
    [ -d "$_root/$_d" ] || continue
    cp -R "$_root/$_d" "$_ps_new/" || { bad "could not copy $_d"; return 1; }
  done
  [ -f "$_ps_new/bin/$PKG" ] || { bad "staged payload has no bin/$PKG"; \
    rm -rf -- "$_ps_new"; return 1; }
  # CLOSED BEFORE THE SWAP in system mode, so the live tree is never open
  # for an instant: root-owned, nothing writable by group or other, and
  # readable by everyone whatever root's umask happened to be, since every
  # user runs it.
  if [ "$_MODE" = system ]; then
    [ "$(id -u)" != 0 ] || chown -R -h root:root "$_ps_new"
    chmod -R u+rwX,go+rX,go-w "$_ps_new"
  fi
  # THE TWO FRAGMENT ALIASES, and they are a COEXISTENCE WINDOW rather than
  # tidiness. The tmux fragments are the only payload files a user names in
  # their OWN config, and that line moved with the layout:
  #
  #   was  source-file ~/.local/share/mux/mux.tmux
  #   now  source-file ~/.local/share/mux/share/mux.tmux
  #
  # Every tmux.conf on every box carries the old spelling, and without an
  # alias the first install after this change leaves mux installed and INERT
  # (no bar, no strip, no bindings) with nothing on screen saying why: the
  # exact state `mux check`'s whole contract exists to prevent, caused by
  # mux. The fleet rule makes the same point generally, that a change with no
  # coexistence window is a self-inflicted red tree.
  #
  # RELATIVE, so the alias survives the payload being moved or copied, and a
  # data-file alias rather than a second command: nothing resolves a PATH
  # through it, so this is not the two-copies-on-PATH hazard in disguise.
  for _f in mux.tmux mux-opinions.tmux; do
    [ -f "$_ps_new/share/$_f" ] && ln -sfn "share/$_f" "$_ps_new/$_f"
  done
  # THE VENV IS CARRIED ACROSS, because the swap below removes the old
  # payload and the venv lives INSIDE it. Without this every re-install
  # destroys the notifier's venv and `~/.local/bin/mux-desktop-notifier`
  # dangles
  # until something rebuilds it: measured in a scratch prefix, planted venv
  # gone and the link pointing at nothing.
  #
  # IT MATTERS BECAUSE THE TWO STEPS ARE SEPARATE. A provisioner installs the
  # package from its pin and runs the indicator's own step afterwards, as a
  # DIFFERENT module, so between them the unit's ExecStart resolves to
  # nothing; run the core install alone (which is every sweep that does not
  # also touch the indicator) and it stays that way. `mux check` would not
  # catch it either: the indicator is a separate package and core's check
  # only reports that it is behind.
  #
  # MOVED RATHER THAN COPIED, which keeps the swap atomic: the venv is tens
  # of megabytes and a copy would double the window in which neither tree is
  # complete. This is hush's shape (f39b763) rather than an invention of
  # mine; `_place-conversion.md` names it as the one to copy, and bt-sane
  # converged on it independently.
  #
  # AND THE ROLLBACK BELOW PUTS IT BACK, because it restores the whole old
  # tree: the venv has already moved into `.new`, so a failed swap would
  # otherwise lose it while appearing to recover.
  if [ -d "$_pay/venv" ] && [ ! -e "$_ps_new/venv" ]; then
    mv -- "$_pay/venv" "$_ps_new/venv" || {
      bad "could not carry the venv across"; rm -rf -- "$_ps_new"
      return 1; }
  fi
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    mv -- "$_pay" "$_ps_old" || { bad "could not move the old payload"; \
      return 1; }
  fi
  mv -- "$_ps_new" "$_pay" || { bad "could not swap in the new payload"
    # THE ROLLBACK HAS TO UNDO THE VENV MOVE TOO, and writing the comment
    # above was what exposed that it did not: restoring the old tree puts
    # back a payload whose venv has already been moved into `.new`, which
    # the next run's first line deletes. So the recovery looked complete and
    # lost tens of megabytes it had just finished protecting.
    if [ -e "$_ps_old" ]; then
      mv -- "$_ps_old" "$_pay"
      [ -d "$_ps_new/venv" ] && [ ! -e "$_pay/venv" ] \
        && mv -- "$_ps_new/venv" "$_pay/venv"
    fi
    return 1; }
  rm -rf -- "$_ps_old"
}

# _retire_old_layout: a LAYOUT switch removes the layout it replaces, which
# the placement rule requires for the same reason a mode switch does: a
# surviving `~/.local/libexec/mux` is the two-copies hazard in another dress,
# and nothing audited for it before.
_retire_old_layout() {
  [ -e "$_oldlib" ] || [ -L "$_oldlib" ] || return 0
  case $_oldlib in
    /*/libexec/?*) ;;
    *) warn "not retiring '$_oldlib': unexpected shape"; return 0 ;;
  esac
  rm -rf -- "$_oldlib"
  rmdir "$PREFIX/libexec" 2>/dev/null || :
  echo "$PKG: retired the old layout at $_oldlib"
}

# _adopt_runtime_state: move per-pane agent records from the unnamespaced
# `$XDG_RUNTIME_DIR/agent-state` to `.../mux/agent-state`, once, HERE, because
# the install is the only moment atomic with the switchover: before it the old
# writers write the old path, after it the new ones write the new one, so
# moving what exists at this instant leaves no second copy to go stale. A hook
# firing mid-move costs one record one event, self-healing on the next
# lifecycle event. DO NOT move this into a reader: mux-agent-state_lib's
# comment carries the measured failure that caused.
#
# A DESTINATION THAT ALREADY EXISTS IS KEPT, NOT COMPARED, with the remedy
# named. Whether the kept record is ACCURATE is a question no timestamp can
# answer, since a beat refreshes mtime without advancing the epoch, so it
# belongs to the verb built for that verdict.
_adopt_runtime_state() {
  _rt=${XDG_RUNTIME_DIR:-}
  [ -n "$_rt" ] && [ -d "$_rt/agent-state" ] || return 0
  _moved=0 _kept=0
  for _nsd in "$_rt"/agent-state/*; do
    [ -d "$_nsd" ] || continue
    _nd=$_rt/mux/agent-state/${_nsd##*/}
    mkdir -p "$_nd" 2>/dev/null || continue
    for _r in "$_nsd"/*; do
      [ -f "$_r" ] || continue
      if [ -e "$_nd/${_r##*/}" ]; then
        rm -f -- "$_r" && _kept=$((_kept + 1))
      else
        mv -- "$_r" "$_nd/" 2>/dev/null && _moved=$((_moved + 1))
      fi
    done
    # `rmdir`, NEVER a recursive delete, and not only for the obvious reason:
    # it REFUSES a directory that still holds something, so anything this did
    # not understand is kept rather than destroyed, and no delete here runs
    # against an expanded variable.
    rmdir "$_nsd" 2>/dev/null || :
  done
  rmdir "$_rt/agent-state" 2>/dev/null || :
  [ "$_moved" -eq 0 ] || { echo "$PKG: adopted $_moved agent record(s)"
    _slog "adopted $_moved agent record(s) from $_rt/agent-state"; }
  [ "$_kept" -eq 0 ] || { echo "$PKG: $_kept agent record(s) were already at"\
    "the new path; if a session reads busy and is not, run"\
    "'mux agent-doctor --repair'"
    # ONE LINE so the corpus can anchor it: a continuation backslash cannot
    # be an anchor, which is failure mode two in test/mutants' own header.
    _slog "kept $_kept record(s) unjudged; mux agent-doctor --repair"; }
  :
}

do_install() {
  mkdir -p "$_bin" "$_shr"
  _payload_stage || return 1
  _ln "$_payt/bin/$PKG" "$_bin/$PKG"
  _man_pages | while IFS= read -r _m; do
    _mr=${_m#"$_root"/}
    _ln "$_payt/$_mr" "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")"
  done
  _retire_old_layout
  echo "$PKG: installed to $_pay (+ bin and man links in $PREFIX)"
  # EVERY STEP BELOW IS ONE USER'S, and as root it would act on /root: the
  # log, the runtime records, that user's live tmux servers, their tmux.conf,
  # their config dir. A live server needs nothing: the fragment calls `mux`
  # by name, and bin/mux ignores an inherited MUX_SHARE that no longer
  # exists, so a switched-away user copy resolves to this one.
  if [ "$_MODE" = system ]; then
    _mode_switch
    echo "$PKG: per-user steps are each user's: a tmux.conf may source" \
      "$_payt/share/mux.tmux, and 'mux check' audits one user's setup"
    return 0
  fi
  _system_leftover && warn "a system install ($_sysbin) shadows this one:" \
    "remove it with 'sudo sh setup.sh uninstall --system'"
  # THE ANCHOR EVENT, and it earns its line by answering a question nothing
  # else on the box can: WHICH mux this machine received and WHEN. The notes
  # have twice had to establish that from a payload mtime against a
  # provisioner log, which only works while both survive.
  _slog "installed $("$_bin/$PKG" -V 2>/dev/null || echo "$PKG ?") to $_pay"
  _adopt_runtime_state
  _reload_live
  _tmux_conf_notice
  _config_readme
  _scan_root_step
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
# A HERE-DOC, NOT A PIPELINE, and the error falls in the direction that
# SUPPRESSES the warning: a `while` fed by a pipe runs in a SUBSHELL, so a
# `return` inside it cannot answer for this function, and a loop that runs
# ZERO times (no tmux.conf at all, which is every fresh box) exits 0, meaning
# "found". The notice would then never fire for the one user who needs it.
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
# inert on the machine that just received it. Only `mux reload` fixes that, so
# the install does it rather than leaving a correct install that behaves like a
# broken one.
#
# IT ALSO CLOSES A PROVISIONER'S LOOP. A provisioner runs `apply` only when
# `check` FAILS, and mux's check correctly FAILS on a stale server, so without
# this the drift is reported for ever by a pin whose install already ran
# ("APPLY DID NOT FIX"). Prevention belongs in the step that made the file
# new.
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
  # ends in a continuation backslash is failure mode two in the corpus's own
  # header and never matches.
  # FOUR SPELLINGS, because two things vary independently and both are real.
  # The TILDE is the form people actually write, and tmux expands it itself,
  # so a guard checking only the expanded path matched nothing and the whole
  # reload was inert on the box it was written for (found by reading the real
  # config, which is why that case exists in the test).
  #
  # And the PATH MOVED with the layout: `<pkg>/mux.tmux` became
  # `<pkg>/share/mux.tmux`, with an alias at the old spelling so every
  # existing tmux.conf keeps working. A guard that accepted only the new one
  # would stop reloading exactly the servers that are mid-migration, which is
  # the population this is for.
  #
  # Each form on its own LINE, so the corpus can mutate either: an anchor that
  # ends in a continuation backslash is failure mode two in the corpus's own
  # header and never matches.
  _rf=$_pay/share/mux.tmux
  _rt="~${_shr#"$HOME"}/$PKG/share/mux.tmux"
  _rfo=$_pay/mux.tmux
  _rto="~${_shr#"$HOME"}/$PKG/mux.tmux"
  _conf_mentions "$_rf" || _conf_mentions "$_rt" \
    || _conf_mentions "$_rfo" || _conf_mentions "$_rto" || return 0
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
  _frag=$_pay/share/mux.tmux
  # ANY mux fragment, not this prefix's: a user who installed elsewhere has
  # already done this step, and nagging them would be wrong. The reload above
  # asks the narrower question on purpose.
  # MATCHES BOTH SPELLINGS ON PURPOSE: `mux/mux.tmux` is the tail of the old
  # path AND of the new `mux/share/mux.tmux`... it is not, so both are asked
  # for explicitly. Tightening this to one spelling makes the notice fire on
  # every box still carrying the old line, which the alias keeps working.
  _conf_mentions "$PKG/share/mux.tmux" && return 0
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

# THE ONE QUESTION A FIRST INSTALL CANNOT ANSWER FOR YOU: where your projects
# live. `mux go <name>` finds a project through the discovery map, and the map
# has no roots until somebody names one.
#
# A SHIPPED ROOT IS NOT AN OPTION: a built-in `scan ~/src 3` is a location
# nobody chose, and then `[FAIL] scan root missing` on every machine that keeps
# work somewhere else, which is most machines. A default is fine; a default
# nobody confirmed is not.
#
# IT ASKS ONLY WITH A TERMINAL, and the reason is the same one that keeps the
# tmux.conf notice from editing your config: a provisioner runs this installer
# on every sweep, so a prompt here would hang it and a silent write would give
# one machine a root the human never named. Without a tty it SAYS, exactly as
# the notice above does.
#
# AND IT IS mux's OWN CONFIG, which is what makes writing it legitimate at all.
# $MUX_DIR is where `mux save`, `mux new` and `mux theme` already write; a
# tmux.conf is the user's file and gets a notice instead. Same rule, opposite
# answer, because the OWNER differs.
_scan_root_step() {
  # Nothing to do when discovery is already configured, which keeps a
  # re-install silent: `mux scan --init` is idempotent and says so itself, so
  # this only has to decide whether to ASK.
  "$_bin/$PKG" scan --roots >/dev/null 2>&1 && return 0
  # THE DECISION BELONGS TO `scan --init`, NOT HERE. It distinguishes the two
  # cases ($HOME is invented, an existing ~/src is observed), so the installer
  # calls it and lets it decide; a second copy of that judgement here is how
  # the two drift. Testing for a terminal HERE and merely printing a note
  # without one is what turns discovery off across a provisioned fleet, since
  # the provisioner has no terminal and nobody reads the line.
  #
  # `|| true` because discovery is OPTIONAL: a box with no obvious project
  # directory still gets a working mux, and `scan --init` has already said
  # what to type. An install must not fail over a convenience.
  "$_bin/$PKG" scan --init || true
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
# _login_home: the sudo caller's home, or nothing. Only SUDO_USER is read: a
# provisioner's own name for the login user is its business, and with none
# the switch names the leftover rather than guessing whose home to edit.
_login_home() {
  _lu=${SUDO_USER:-}
  [ -n "$_lu" ] && [ "$_lu" != root ] || return 0
  getent passwd "$_lu" | cut -d: -f6
}

# _user_copies HOME: the user-mode pieces that may not coexist with a system
# install, one per line. The payload's CODE only: its `venv` is the desktop
# notifier's, which stays per-user, so the payload directory itself is not
# named and survives as the venv's home.
_user_copies() {
  for _uc in "$1/.local/bin/$PKG" "$1/.local/share/man/man1/$PKG.1" \
             "$1/.local/share/$PKG/bin" "$1/.local/share/$PKG/lib" \
             "$1/.local/share/$PKG/libexec" "$1/.local/share/$PKG/share" \
             "$1/.local/share/$PKG/man" "$1/.local/share/$PKG/mux.tmux" \
             "$1/.local/share/$PKG/mux-opinions.tmux"; do
    if [ -e "$_uc" ] || [ -L "$_uc" ]; then echo "$_uc"; fi
  done
  return 0
}

# _mode_switch: user to system, in the same install. Each removal is pinned
# to its exact shape first, per the standing rm rule, and runs as root inside
# a user's home, so nothing outside those literal shapes is ever touched.
_mode_switch() {
  _lh=$(_login_home)
  case $_lh in
    /?*) ;;
    *) echo "$PKG: no sudo caller, so no user-mode copy was looked for;" \
         "that user's 'mux check' names one if it exists" >&2
       return 0 ;;
  esac
  for _uc in $(_user_copies "$_lh"); do
    case $_uc in
      "$_lh/.local/bin/$PKG"|"$_lh/.local/share/man/man1/$PKG.1"|\
      "$_lh/.local/share/$PKG/mux.tmux"|\
      "$_lh/.local/share/$PKG/mux-opinions.tmux") rm -f -- "$_uc" ;;
      "$_lh/.local/share/$PKG"/bin|"$_lh/.local/share/$PKG"/lib|\
      "$_lh/.local/share/$PKG"/libexec|"$_lh/.local/share/$PKG"/share|\
      "$_lh/.local/share/$PKG"/man) rm -rf -- "$_uc" ;;
      *) continue ;;
    esac
    echo "$PKG: removed the user-mode $_uc (mode switch to system)"
  done
  rmdir "$_lh/.local/share/$PKG" 2>/dev/null || :
  # THE USER'S tmux.conf IS SAID, NEVER EDITED (it is theirs, the rule the
  # user-mode notice already keeps). A line sourcing the removed copy now
  # names a missing file; mux re-wires a server on its next session verb
  # either way, so this is a stale line rather than a dead bar.
  for _c in "$_lh/.config/tmux/tmux.conf" "$_lh/.tmux.conf"; do
    grep -q -- '\.local/share/mux' "$_c" 2>/dev/null || continue
    echo "$PKG: NOTE $_c sources the removed user copy; point it at" >&2
    echo "$PKG:      source-file $_payt/share/mux.tmux" >&2
  done
}

# _system_leftover: is there a system-mode command beside a user install?
_system_leftover() { [ -e "$_sysbin" ] || [ -L "$_sysbin" ]; }

# when no indicator is installed: an optional sub-package must not make the
# core install noisy for everyone who does not use it.
_indicator_notice() {
  [ -e "$_bin/mux-desktop-notifier" ] || return 0
  sh "$_root/desktop-notifier/setup.sh" check >/dev/null 2>&1 && return 0
  echo "$PKG: NOTE the installed desktop notifier differs from this" >&2
  echo "$PKG:      (or its daemon is running older code). It polls a mux" >&2
  echo "$PKG:      contract, so leaving it behind loses items silently." >&2
  echo "$PKG:      package. Refresh it with: ./setup.sh desktop-notifier" >&2
  # LOGGED BECAUSE `mux check` CANNOT SEE IT: the verdict comes from the
  # indicator's own three-copy check, which core deliberately does not run.
  # So without this the skew is reported once, to a terminal that may not
  # exist, and never again.
  _slog "the installed notifier is behind: ./setup.sh desktop-notifier"
}

do_uninstall() {
  # Noted BEFORE the payload goes, since the evidence is inside it.
  _had_venv=
  [ -d "$_pay/venv" ] && _had_venv=1
  _rmln "$_payt/bin/$PKG" "$_bin/$PKG"
  # The OLD link target too, so uninstalling a pre-migration install works.
  _rmln "$_root/bin/$PKG" "$_bin/$PKG"
  _man_pages | while IFS= read -r _m; do
    _mt=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    _rmln "$_payt/${_m#"$_root"/}" "$_mt"
    _rmln "$_m" "$_mt"
  done
  _rmln "$_root/share" "$_shr/$PKG"     # a pre-migration share link
  _retire_old_layout
  if [ -d "$_pay" ] && [ ! -L "$_pay" ]; then
    case $_pay in
      /*/*) rm -rf -- "$_pay" ;;
      *) bad "refusing to remove a payload at '$_pay'" ;;
    esac
  fi
  echo "$PKG: removed $_pay and its links from $PREFIX"
  if [ "$_MODE" = system ]; then
    echo "$PKG: every user's own config, state and runtime are theirs and" \
      "were not touched"
    return 0
  fi
  # A REMOVAL IS A MUTATION, which is exactly what this log is for, and it
  # answers the awkward question afterwards: mux went away, by what and when.
  _slog "removed $_pay and its links from $PREFIX"
  # THE INDICATOR'S VENV LIVES INSIDE THE PAYLOAD NOW, so removing the
  # payload took it too. Said rather than left to be discovered: its bin
  # link and its systemd unit are still there and now point at nothing, and
  # a dangling unit that fails at every login is worse than one that is gone.
  [ -z "$_had_venv" ] || {
    echo "$PKG: that INCLUDED the indicator's venv, so its unit and"
    echo "$PKG:   $_bin/$PKG-desktop-notifier now dangle. Clean them up"
    echo "$PKG:   sh desktop-notifier/setup.sh uninstall"; }
  # AND IT SAYS WHAT IT KEPT. Keeping these is right, because a session set
  # and a log are not the package's to delete; saying nothing about them is
  # not, because "uninstalled" then reads as "gone" while they sit on disk.
  echo "$PKG: KEPT your own files, delete them by hand if you mean to:"
  do_paths | while IFS="$(printf '\t')" read -r _k _v; do
    case $_k in
      config|state|cache) [ -e "$_v" ] && echo "$PKG:   $_k  $_v" ;;
    esac
  done
}

do_check() {
  echo "== $PKG (package install) =="
  [ "$(readlink "$_bin/$PKG" 2>/dev/null)" = "$_payt/bin/$PKG" ] \
    && ok "bin/$PKG links into the payload" \
    || bad "bin/$PKG does not link to $_payt/bin/$PKG"
  # THE PAYLOAD IS A TREE, NOT A LINK, which is the whole migration: a
  # symlink here means the install still depends on a source checkout and
  # dies when it moves.
  if [ -L "$_pay" ]; then
    bad "$_pay is a SYMLINK: this install still depends on a source tree"
  elif [ -d "$_pay" ] && [ -f "$_pay/bin/$PKG" ] \
      && [ -d "$_pay/libexec" ] && [ -d "$_pay/share" ]; then
    ok "payload is a self-contained tree ($_pay)"
  else
    bad "no payload tree at $_pay: reinstall mux"
  fi
  # A RETIRED LAYOUT PATH THAT SURVIVED. A WARN rather than a FAIL: nothing
  # resolves through it (libexec was never on PATH and bin/mux self-locates),
  # so it is stale rather than broken, and the fleet is mid-transition.
  if [ -e "$_oldlib" ] || [ -L "$_oldlib" ]; then
    warn "retired layout path survives: $_oldlib (reinstall removes it)"
  else
    ok "no retired layout path"
  fi
  # ONE COPY ON PATH, from whichever side: a leftover of the OTHER mode is a
  # FAIL, named, because /usr/local/bin shadows ~/.local/bin and the shadowed
  # copy then rots.
  if [ "$_MODE" = system ]; then
    _check_system
    return 0
  fi
  if _system_leftover; then
    bad "a system install ($_sysbin) exists too: two copies on PATH, and" \
      "the system one shadows this"
  fi
  "$_root/bin/mux" check || RC=1      # deps + package data (its own markers)
}

# _check_system: what only the machine-wide mode owes. Ownership and modes
# are read with find, which needs no privilege on a world-readable tree, so
# a non-root caller gets the same verdict root does. `mux check` itself is
# NOT run: it audits one user's config, state and tmux, and as root that is
# /root's, which reports on nobody who uses this install.
_check_system() {
  # A DESTDIR stage is a non-root build, so ownership is asked only of a
  # real install; the modes are asked of both.
  if [ -d "$_pay" ]; then
    _open=$(find "$_pay/" ! -type l \( -perm -0002 -o -perm -0020 \) -print \
      2>/dev/null | head -n 1)
    [ -n "$_open" ] || [ -n "$_dest" ] || _open=$(find "$_pay/" ! -user root \
      -print 2>/dev/null | head -n 1)
    if [ -n "$_open" ]; then
      bad "the system payload is not root-owned and closed: $_open"
    else
      ok "the system payload is root-owned and closed"
    fi
  fi
  _lh=$(_login_home)
  case $_lh in
    /?*)
      _left=$(_user_copies "$_lh")
      if [ -n "$_left" ]; then
        bad "user-mode copy beside the system install (two copies):" \
          "$(echo "$_left" | head -n 1)"
      else
        ok "no user-mode copy for $SUDO_USER"
      fi ;;
  esac
  if command -v tmux >/dev/null 2>&1; then ok "tmux on PATH"
  else bad "tmux not on PATH (mux drives tmux)"; fi
  echo "  [INFO] per-user setup is each user's: run 'mux check' as them"
}

# --- paths: the ONE declaration of every root this package owns -----------
# PART OF THE PACKAGE CONTRACT (the fleet's install-placement rule, ruled
# 2026-10-01): one declaration feeds the four things that each otherwise
# guess, which is the whole argument for it being a verb rather than prose:
# the install audit, the stale-path sweep, uninstall saying what it kept, and
# discoverability.
#
# `KIND PATH` PER LINE, two fields, because a consumer wants to act per KIND
# (remove a payload, never a config) and parsing prose is how an integrator
# ends up with its own copy of the list. Tab-separated for the reason every
# other record in this package is: a path may contain a space.
#
# EVERY VALUE IS DERIVED, never restated: these are the same expressions the
# installer and mux itself resolve, so a root cannot be renamed in one place
# and still reported from here. That is the failure the verb exists to make
# impossible, and a hand-written list would reintroduce it.
#
# RUNTIME IS REPORTED AS THE DIRECTORY MUX OWNS, not the XDG root: naming the
# whole runtime dir would invite a sweep to delete another tool's socket. It
# is `<runtime>/mux` now rather than `<runtime>/agent-state`, which is the
# namespacing the same ruling asked for: agent state used to sit under a
# generic name beside at-spi, bus, dbus-1 and gcr.
do_paths() {
  printf 'bin\t%s\n'     "$_bin/$PKG"
  printf 'payload\t%s\n' "$_shr/$PKG"
  printf 'man\t%s\n'     "$_man/man1/$PKG.1"
  # SYSTEM MODE OWNS ONLY THE MACHINE'S ROOTS. Config, state, cache, runtime
  # and the notifier's venv belong to each user, and printing root's would
  # name directories nobody who uses this install ever reads.
  if [ "$_MODE" = system ]; then
    printf 'policy\t%s\n' "/etc/$PKG/send-policy"
    return 0
  fi
  printf 'config\t%s\n'  "${MUX_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$PKG}"
  _p_st=${XDG_STATE_HOME:-$HOME/.local/state}
  printf 'state\t%s\n'   "${MUX_STATE:-$_p_st/$PKG}"
  printf 'cache\t%s\n'   "${MUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/$PKG}"
  _p_rt=${XDG_RUNTIME_DIR:-/tmp/user-$(id -u)}
  printf 'runtime\t%s\n' "$_p_rt/$PKG"
  printf 'venv\t%s\n'    "${MUX_DESKTOP_NOTIFIER_VENV:-$_pay/venv}"
  printf 'policy\t%s\n'  "/etc/$PKG/send-policy"
}

_U="usage: setup.sh [install|uninstall|check|paths [--system]|test|version|\
all|desktop-notifier]"
# --- ARGUMENTS PAST THE VERB ARE REFUSED, NEVER IGNORED --------------------
# FOUND BY MAKING THE MISTAKE, on a live box: `sh setup.sh install
# PREFIX=/var/tmp/scratch` installed to the REAL prefix and printed its usual
# success line, because PREFIX is an ENVIRONMENT variable and `$2` was never
# looked at. The verb dispatch below has always refused an unknown VERB; what
# it could not see was an unknown argument AFTER a known one.
#
# THAT IS THE PLAUSIBLE-WRONG-OUTCOME SHAPE this package keeps cataloguing,
# and it is at its worst in an installer: the caller named a destination, the
# script wrote somewhere else, and said it succeeded. It retargeted a deployed
# install and reloaded a live tmux server, which is exactly the accident this
# file's own notes warn about testing against a scratch PREFIX to avoid.
#
# A SETTING GETS ITS OWN MESSAGE, because that is the mistake a human actually
# makes and a bare "unexpected argument" would leave them guessing which form
# is wanted. Matched on `*=*` rather than on a `[A-Z]*=*` range, since a
# bracket range is a COLLATION range and admits surprises in another locale:
# the match only chooses the WORDING here, so the loose, locale-proof test is
# the right one.
_badarg() {   # <verb> <offending argument>
  case $2 in
    *=*)
      printf 'setup.sh: %s is a SETTING, not an argument.\n' "$2" >&2
      printf '  Settings come from the environment, so:  %s sh setup.sh %s\n' \
        "$2" "$1" >&2 ;;
    *)
      printf "setup.sh: unexpected argument '%s' after '%s'\n" "$2" "$1" >&2 ;;
  esac
  printf '%s\n' "$_U" >&2
  exit "$MUX_EC_USAGE"
}
# `desktop-notifier` is the one verb that legitimately takes more: it passes a
# verb and its flags straight through to the sub-package.
#
# `indicator` WAS ACCEPTED HERE TOO, as the former name, which is what let the
# provisioner that calls this by name move independently rather than needing a
# flag day. Both repos have been renamed and deployed, so the overlap has done
# its job and gone: an alias nobody uses is a second spelling to keep working.
# `--system` is the one FLAG, and only on the verbs that have a system mode:
# accepting it anywhere else would install somewhere the caller did not ask
# for, which is the very accident this guard exists for.
case "${1:-help}" in
  desktop-notifier) ;;
  install|uninstall|check|paths)
    if [ "${2:-}" = --system ]; then
      [ "$#" -le 2 ] || _badarg "$1" "$3"
    else
      [ "$#" -le 1 ] || _badarg "$1" "$2"
    fi ;;
  *) [ "$#" -le 1 ] || _badarg "${1:-help}" "$2" ;;
esac

case "${1:-help}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    check)     do_check; exit "$RC" ;;
    paths)     do_paths ;;
    test)      exec sh "$_root/test/run" ;;
    version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null \
                 || true)
               echo "${_v:-$PKG (unversioned)}" ;;
    all)       do_install; sh "$_root/desktop-notifier/setup.sh" install ;;
    desktop-notifier)                                        # passthrough
               shift; exec sh "$_root/desktop-notifier/setup.sh" "$@" ;;
    -h|--help|help) echo "$_U" ;;
    *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2
       exit "$MUX_EC_USAGE" ;;
esac
