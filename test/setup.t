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

# --- NOTHING SOURCING THE FRAGMENT IS SAID, NOT FIXED -----------------------
# Linking mux into PATH does nothing VISIBLE: the bar, the strip and the
# bindings all come from `source-file .../mux.tmux` in the user's own
# tmux.conf, so until that line exists mux looks installed and inert. That is
# the "fully installed and fully broken" state one step earlier than the one
# `mux check` was built for.
#
# SAID, NEVER EDITED: a tmux.conf is the user's own file, not a package input,
# and an installer that rewrote it as a side effect of `install` is the one
# irreversible mistake available here. Asserted, so nobody "improves" it into
# an edit.
run install >"$T/out" 2>&1 || fail "reinstall errored"
grep -q 'source-file' "$T/out" || fail "the install said nothing about sourcing
the fragment, so a new user gets a working install with no visible mux and
nothing telling them why"
grep -q 'setup claude' "$T/out" || fail "the notice did not point at the next
step; the two manual steps are the whole first-run problem"
[ -e "$T/.tmux.conf" ] && fail "the installer CREATED a tmux.conf: that file is
the user's, and writing it is the one thing this notice exists to avoid"

# ... and SILENT once the line is there, or a re-install is noise and people
# learn to skip the output that matters.
mkdir -p "$T/conf-tmux"
printf 'source-file %s/share/mux/mux.tmux\n' "$T" >"$T/conf-tmux/tmux.conf"
_o=$(env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
  HOME="$T" XDG_CONFIG_HOME="$T/conf-tmux-parent" \
  sh "$HERE/setup.sh" install 2>&1) || fail "install errored"
mkdir -p "$T/conf-tmux-parent/tmux"
printf 'source-file %s/share/mux/mux.tmux\n' "$T" \
  >"$T/conf-tmux-parent/tmux/tmux.conf"
_o=$(env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
  HOME="$T" XDG_CONFIG_HOME="$T/conf-tmux-parent" \
  sh "$HERE/setup.sh" install 2>&1) || fail "install errored"
case $_o in
*source-file*) fail "the notice fired with the fragment already sourced:
$_o" ;;
esac

# --- AN INSTALLED INDICATOR THAT HAS FALLEN BEHIND IS SAID, NOT FIXED -------
# The indicator is a separate package that core neither installs nor owns, but
# it POLLS a mux contract (`mux agent status`, JSON), and a skew there fails
# silently: a daemon built against an older contract keeps polling and just
# publishes fewer items, which reads as "that partition is gone" rather than as
# a version problem. So a core install says so.
#
# NOT A RESTART, which is the part worth asserting: restarting would not help,
# because what is stale is the daemon's own code rather than anything it caches
# from core: it re-execs `mux` every poll. And not an install, which is a pip
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

# --- DISCOVERY: WHAT THE INSTALL DOES ABOUT NO ROOTS ----------------------
# mux used to SHIP `scan ~/src 3`, so this state was unreachable and every
# machine without that directory got `[FAIL] scan root missing` from mux's own
# check instead.
#
# AND HOME IS PINNED HERE, WHICH IT WAS NOT BEFORE. The earlier version of
# this case let the installer see the REAL home directory, so which branch it
# took depended on whether the developer happened to have ~/src: a test that
# silently measures the machine it runs on rather than the code. Both branches
# are driven explicitly now.
runmd() {   # the installer, with mux's config dir and HOME pinned
  env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
    MUX_DIR="$T/conf-mux" HOME="$1" sh "$HERE/setup.sh" install
}

# NOTHING TO OBSERVE: it must write NOTHING and say what to type. A
# provisioner runs this on every sweep with no tty, and writing $HOME as a
# scan root there would index a whole home directory on a guess, which is the
# original defect wearing a different hat. The assertion is on the ABSENCE of
# the file.
mkdir -p "$T/h-bare"
runmd "$T/h-bare" >"$T/out" 2>&1 || fail "reinstall errored"
grep -q 'needs a terminal' "$T/out" || fail "with nothing configured and
nothing to observe, the install said nothing about discovery, so a new user
gets a mux whose \`mux go <name>\` finds no projects and no hint why:
$(cat "$T/out")"
grep -q 'mux scan --init' "$T/out" || fail "the notice did not name the command
that fixes it; a gap named without a remedy invites two different fixes"
[ -e "$T/conf-mux/partitions/global.partition" ] && fail "the installer WROTE a
scan root with no terminal and no ~/src to observe. A provisioner runs this on
every sweep; indexing a whole \$HOME on a guess is the defect this removes"

# AN EXISTING ~/src IS OBSERVED, NOT INVENTED, so the install records it even
# with no terminal. THE ABSENCE OF THIS IS WHAT BROKE A PROVISIONED FLEET:
# 0.85 removed the shipped default and left a migration that only ran at a
# terminal, so the provisioner printed a line nobody read and discovery went
# from working to off, silently, on every box.
rm -rf "$T/conf-mux"
mkdir -p "$T/h-src/src"
runmd "$T/h-src" >"$T/out" 2>&1 || fail "reinstall errored"
grep -qE "^scan[[:space:]]+$T/h-src/src 3\$" \
  "$T/conf-mux/partitions/global.partition" 2>/dev/null \
  || fail "with ~/src present the install recorded no scan root, so a
provisioned box silently loses discovery:
$(cat "$T/out")"

# ... and SILENT once roots exist, or a re-install is noise people skip.
runmd "$T/h-src" >"$T/out" 2>&1 || fail "reinstall errored"
grep -qE 'needs a terminal|no terminal to ask' "$T/out" && fail "the discovery
step spoke again with a root already configured: $(cat "$T/out")"
rm -rf "$T/conf-mux"

# --- A LIVE SERVER IS RELOADED, because installing a file does not ----------
# This package's most expensive recurring bug: a running tmux keeps the
# bindings, hooks and status format it read at START, so a new binding is inert
# on the machine that just received it. `mux undo-pane` was unreachable on two
# boxes for two releases that way and `prefix ?` repeated it. It also loops a
# provisioner forever, because apply runs only when check FAILS and mux's check
# now correctly fails on a stale server.
#
# THE DEFAULT SOCKET IS WHAT `mux reload` FRESHENS, so this drives that rather
# than a fresh named one, which is safe ONLY because harness_lib pins
# TMUX_TMPDIR inside $T. Without that pin this case would source a
# scratch config into the developer's own live server.
if command -v tmux >/dev/null 2>&1; then
  _inst() {
    env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
      HOME="$T" XDG_CONFIG_HOME="$T/conf-tmux-parent" PATH="$T/bin:$PATH" \
      sh "$HERE/setup.sh" install 2>&1
  }
  _sr() { tmux show-options -gv status-right 2>/dev/null || true; }
  if env HOME="$T" PATH="$T/bin:$PATH" tmux new-session -d -s reloadme \
      -x 80 -y 24 2>/dev/null; then
    # A CONFIG THAT NAMES SOMEBODY ELSE'S INSTALL IS LEFT ALONE, first,
    # because that is the case where reloading would push an unrelated
    # config into servers that never ran this prefix.
    #
    # THE FIXTURE IS A VALID CONF THAT SETS SOMETHING OBSERVABLE, which is
    # the only version that can FAIL. The first attempt used a conf whose
    # single line was `source-file /nowhere/else/mux.tmux`: sourcing it
    # errors, so nothing changed either way and deleting the guard was
    # undetectable. A fixture that cannot express the bug proves nothing.
    printf "set -g status-right 'SOMEONE-ELSES-CONF'\n" \
      >"$T/conf-tmux-parent/tmux/tmux.conf"
    tmux set-option -g status-right 'STALE' 2>/dev/null
    _o=$(_inst) || fail "install errored with a live server"
    [ "$(_sr)" = STALE ] || fail "the install reloaded a server whose config
does not source THIS install's fragment, so it pushed an unrelated config:
status-right is now [$(_sr)]"
    case $_o in
    *reloaded*) fail "install claimed a reload it must not have done: $_o" ;;
    esac

    # ... and one that DOES name it is brought current, which is the whole
    # point: the assertion is on the live server's own option, not on the
    # message, because a message is what the old behaviour already had.
    printf 'source-file %s/share/mux/mux.tmux\n' "$T" \
      >"$T/conf-tmux-parent/tmux/tmux.conf"
    _o=$(_inst) || fail "install errored reloading a live server"
    case $(_sr) in
    *'mux agent-render'*) ;;
    *) fail "a live server running THIS install was not brought current by the
install: status-right is [$(_sr)]. A binding or hook added by this release is
inert on this machine, and mux check reports drift that apply cannot fix." ;;
    esac
    case $_o in
    *reloaded*) ;;
    *) fail "the install reloaded a server and did not say so: $_o" ;;
    esac

    # ... AND THE TILDE FORM, which is the one people actually write and the
    # one that shipped: `source-file ~/.local/share/mux/mux.tmux`. tmux expands
    # the `~` itself, so a guard checking only the expanded path matched
    # nothing and the whole reload was inert on the box it was written for.
    # Found by reading the real config rather than by any test, which is why
    # this case exists.
    tmux set-option -g status-right 'STALE' 2>/dev/null
    printf 'source-file ~/share/mux/mux.tmux\n' \
      >"$T/conf-tmux-parent/tmux/tmux.conf"
    _o=$(_inst) || fail "install errored on the tilde form"
    case $(_sr) in
    *'mux agent-render'*) ;;
    *) fail "a config written with a TILDE was not recognised, so the reload
never fires on a real machine: status-right is [$(_sr)]" ;;
    esac
    tmux_drop_socket default
  fi
fi

# uninstall: every link removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
[ -e "$T/bin/mux" ] && fail "bin/mux link not removed"
[ -e "$T/libexec/mux" ] && fail "libexec/mux link not removed"
[ -e "$T/share/mux" ] && fail "share/mux link not removed"

# --- THE CONFIG ROOT CARRIES A README NAMING EVERY LOCATION ---------------
# WHY THIS EXISTS: mux keeps things in five roots and a user looking for one
# of them had to read source. That is how this whole review started, with the
# shipped envhooks.d reported as "missing from ~/.config/mux" when it is in
# the payload by design, where an upgrade can replace it without touching
# anything of the user's.
#
# A README RATHER THAN A SYMLINK, deliberately: the convenient answer is a
# `logs -> ...state/mux` link in the config dir, and $MUX_DIR is designed to
# be SHARED between machines, so such a link either carries a session set into
# a dotfiles repo or dangles on the other box. A README can SAY which roots
# are shared and which are per-machine; a symlink cannot.
mkdir -p "$T/h-readme"
runmd "$T/h-readme" >"$T/out" 2>&1 || fail "install errored"
_rm=$T/conf-mux/README
[ -s "$_rm" ] || fail "install wrote no README into the config root, so every
location mux uses is still only discoverable by reading source: $(cat "$T/out")"

# EVERY ROOT MUX ACTUALLY USES MUST BE NAMED, and the list is SCRAPED from the
# source rather than restated here: a hand-written list in a test is the
# second copy that drifts, and the failure it would hide is a new root nobody
# documents. mux-paths_lib owns the cache and state derivations; the config
# and share roots are bin/mux's.
for _v in MUX_DIR MUX_SHARE MUX_STATE MUX_CACHE XDG_RUNTIME_DIR; do
  grep -q "\$$_v" "$_rm" \
    || fail "the README never names \$$_v, which mux resolves and writes
under, so a user looking for it is back to reading source"
done

# AND IT SAYS WHICH ARE SHAREABLE AND WHICH ARE NOT, which is the half a
# symlink could never express and the reason the symlink was refused.
grep -qi 'shareable' "$_rm" || fail "the README does not say which roots are
shareable between machines, which is the property that decides whether a
dotfiles repo may carry one"
grep -qi 'machine-local' "$_rm" || fail "the README does not mark the
machine-local roots, so it reads as though all five could be shared"

# IT POINTS AT THE SHIPPED DEFAULTS BY PATH, and that path must be real: the
# whole complaint was that these look absent.
grep -q 'envhooks.d' "$_rm" || fail "the README does not say where the SHIPPED
envhooks live, which is the exact confusion it exists to end"

# AND IT NEVER EATS SOMETHING A HUMAN WROTE. The marker line is the test: with
# it gone the file is the user's, and an installer that rewrites it anyway is
# the one unrecoverable mistake available here.
printf 'my own notes\n' >"$_rm"
runmd "$T/h-readme" >"$T/out" 2>&1 || fail "install errored over a user README"
[ "$(cat "$_rm")" = 'my own notes' ] \
  || fail "the installer OVERWROTE a README a human had edited:
[$(cat "$_rm")]"
grep -qi 'left your own' "$T/out" || fail "it left the file alone and said
nothing, so the user never learns why their README stopped being updated:
$(cat "$T/out")"

# --- `setup.sh paths`: ONE declaration of every root ----------------------
# PART OF THE PACKAGE CONTRACT (the fleet install-placement rule): one
# declaration feeds the install audit, the stale-path sweep, uninstall saying
# what it kept, and discoverability. Its only real failure mode is DRIFT, so
# that is what these assert: a verb that reports a root mux does not use is
# worse than no verb, because four consumers then act on it.
_pth() { env -u MUX_SHARE MUX_DIR="$T/conf-mux" MUX_STATE="$T/st" \
  MUX_CACHE="$T/ca" PREFIX="$T" XDG_DATA_HOME="$T/share" \
  sh "$HERE/setup.sh" paths; }

_po=$(_pth) || fail "setup.sh paths failed"
[ -n "$_po" ] || fail "paths printed nothing, so every consumer of the
contract has to guess again"

# TWO TAB-SEPARATED FIELDS AND AN ABSOLUTE PATH, per line. A consumer acts
# PER KIND (remove a payload, never a config), so a malformed line is a
# consumer deleting the wrong thing.
printf '%s\n' "$_po" | while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  case $_l in
  *"	"*) ;;
  *) echo "NOTAB $_l" ;;
  esac
  case ${_l#*	} in
  /*) ;;
  *) echo "NOTABS $_l" ;;
  esac
done >"$T/pbad"
[ ! -s "$T/pbad" ] || fail "malformed paths line(s), so a consumer parsing
KIND and acting on PATH would act on something else: $(cat "$T/pbad")"

# EVERY KIND APPEARS ONCE. A duplicate makes "the" payload ambiguous.
_pk=$(printf '%s\n' "$_po" | cut -f1 | sort)
_pn=$(printf '%s\n' "$_pk" | wc -l)
_pu=$(printf '%s\n' "$_pk" | sort -u | wc -l)
[ "$_pn" = "$_pu" ] \
  || fail "a KIND is reported twice, so a consumer cannot tell which path is
the one it should act on: [$(printf '%s' "$_pk" | tr '\n' ' ')]"

# THE KINDS THE RULE NAMES must all be there, or a consumer silently skips a
# root: the stale-path sweep would then leave it behind forever.
for _k in bin payload man config state cache runtime venv policy; do
  printf '%s\n' "$_po" | cut -f1 | grep -qxF -- "$_k" \
    || fail "paths never reports the '$_k' root, so whatever consumes this
contract cannot audit, sweep or report it"
done

# IT HONOURS THE OVERRIDES, which is what makes it usable by a consumer
# running against a scratch prefix rather than only against a real install.
_pv=$(printf '%s\n' "$_po" | awk -F'\t' '$1 == "config" { print $2 }')
[ "$_pv" = "$T/conf-mux" ] || fail "paths ignored MUX_DIR and reported
[$_pv], so it describes the developer's own machine rather than the install
it was asked about"

# AND IT AGREES WITH WHAT MUX ITSELF RESOLVES, which is the whole point of
# one declaration and the only assertion here that can catch drift. Both
# sides are DERIVED: the verb from the installer's expressions, mux from its
# own libs, so a root renamed in one place and not the other fails here.
_pstate=$(printf '%s\n' "$_po" | awk -F'\t' '$1 == "state" { print $2 }')
_mlog=$(env -u MUX_SHARE MUX_STATE="$T/st" "$HERE/bin/mux" log --path \
  2>/dev/null) || fail "mux log --path failed"
case $_mlog in
"$_pstate"/*) ;;
*) fail "paths says state is [$_pstate] but mux writes its log to [$_mlog],
so the contract and the program disagree about where state lives" ;;
esac

pass
