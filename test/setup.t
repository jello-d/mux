#!/bin/sh
# setup.t - setup.sh install -> assert links -> check -> uninstall -> assert
# gone, all against a scratch PREFIX. Nothing outside the sandbox is touched.
_name=setup
. "$(dirname "$0")/harness_lib"     # HERE=repo root, T=scratch, fail/pass

# XDG_RUNTIME_DIR comes from harness_lib ($T/run) and is NOT re-derived here:
# `install` moves live agent records, so an unpinned run would reach into the
# developer's own. Named rather than inherited silently, because the pin is
# what makes the adoption case below safe to write at all.
run() {
  env PREFIX="$T" XDG_BIN_HOME="$T/bin" XDG_DATA_HOME="$T/share" NO_COLOR=1 \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" sh "$HERE/setup.sh" "$@"
}

# --- INSTALL IS ONE PAYLOAD TREE PLUS TWO LINKS ---------------------------
# THE MIGRATION ITSELF (fleet install-placement rule, ruled 2026-10-01). Every
# root used to be a SYMLINK into the source clone, so an installed mux died
# the moment that clone moved: measured, with the source gone the entry point
# answered `No such file or directory` and nothing could diagnose it, because
# mux was the thing that had gone.
run install >/dev/null 2>&1 || fail "install errored"
_pay=$T/share/mux
[ "$(readlink "$T/bin/mux")" = "$_pay/bin/mux" ] \
  || fail "bin/mux does not link into the payload:
[$(readlink "$T/bin/mux")]"
[ -e "$T/share/man/man1/mux.1" ] || fail "man page not linked"

# A TREE, NOT A LINK, which is the whole point and the one assertion that
# would have caught the old layout.
[ ! -L "$_pay" ] || fail "the payload is a SYMLINK, so this install still
depends on a source checkout and dies when it moves"
for _d in bin lib libexec share; do
  [ -d "$_pay/$_d" ] && [ ! -L "$_pay/$_d" ] \
    || fail "$_pay/$_d is missing or a link, so the payload is not
self-contained"
done

# AND THE SIBLINGS ARE WHY `<payload>/share` IS NESTED, which reads as a wart
# and is load-bearing: `bin/mux` resolves $0 and reads ../lib, ../libexec and
# ../share, which is what makes a checkout, a Homebrew keg and a relocated
# install all work. Asserted so nobody flattens it to tidy the name away.
[ -f "$_pay/bin/mux" ] || fail "no entry point inside the payload"
[ -d "$_pay/share/themes" ] \
  || fail "the payload's share/ is not where mux's data landed, so sibling
self-location cannot find it"

# THE OLD LAYOUT IS RETIRED, not left to rot: a surviving
# ~/.local/libexec/mux is the two-copies hazard in another dress.
[ ! -e "$T/libexec/mux" ] \
  || fail "install left the retired layout path $T/libexec/mux in place"

# check: the payload lines are green (tmux may be absent in a sandbox, so
# tolerate a non-zero overall rc and assert the lines directly)
run check >"$T/out" 2>&1 || true
grep -q 'links into the payload' "$T/out" \
  || fail "check missing the bin link OK line: $(cat "$T/out")"
grep -q 'self-contained tree' "$T/out" \
  || fail "check does not assert the payload is a tree: $(cat "$T/out")"
grep -q 'no retired layout path' "$T/out" \
  || fail "check does not audit for a retired layout path: $(cat "$T/out")"

# --- IT SURVIVES ITS SOURCE GOING AWAY -----------------------------------
# The property the migration exists for, asserted rather than described. A
# COPY of the tree is used, never $HERE, because deleting the real checkout
# is not a thing a test may do.
# COPIED FROM THE WORKING TREE, never `git archive HEAD`, and the first
# version got this wrong in the direction that reports a false failure: the
# archive carries the COMMITTED installer, so it built the OLD symlink layout
# and then correctly died when the copy went away. A test of an installer has
# to run the installer under test.
_cp=$T/srccopy
mkdir -p "$_cp"
for _d in bin lib libexec share man; do
  [ -d "$HERE/$_d" ] && cp -R "$HERE/$_d" "$_cp/"
done
cp "$HERE/setup.sh" "$_cp/setup.sh" 2>/dev/null || _cp=
if [ -n "$_cp" ] && [ -f "$_cp/setup.sh" ]; then
  env PREFIX="$T/p2" XDG_BIN_HOME="$T/p2/bin" XDG_DATA_HOME="$T/p2/share" \
    NO_COLOR=1 MUX_DIR="$T/conf2" sh "$_cp/setup.sh" install >/dev/null 2>&1 \
    || fail "install from the source copy errored"
  "$T/p2/bin/mux" -V >/dev/null 2>&1 || fail "the copied install does not run"
  rm -rf -- "$_cp"
  "$T/p2/bin/mux" -V >/dev/null 2>&1 \
    || fail "with its SOURCE REMOVED the installed mux no longer runs, which
is exactly the dependency this layout was changed to remove"
else
  printf 'note %s: could not copy the tree, source-removal unchecked\n' \
    "$_name"
fi

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
: >"$T/bin/mux-desktop-notifier"
run install >"$T/out" 2>&1 || fail "install errored with an indicator present"
grep -q 'tray indicator' "$T/out" || fail "an installed indicator that does not
match the package was not reported, so a silent tray skew is the default:
$(cat "$T/out")"
grep -q 'setup.sh indicator' "$T/out" || fail "the notice did not name the
command that fixes it; a gap named without a remedy invites two different fixes"
rm -f "$T/bin/mux-desktop-notifier"

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
    # BOTH TILDE SPELLINGS, because the fragment path moved with the layout
    # and an alias keeps the OLD one working: `<pkg>/mux.tmux` became
    # `<pkg>/share/mux.tmux`. With four spellings accepted (expanded or
    # tilde, old path or new) a fixture using only one leaves the other three
    # unkillable, which the corpus said out loud by surviving.
    for _tf in 'share/mux/mux.tmux' 'share/mux/share/mux.tmux'; do
      tmux set-option -g status-right 'STALE' 2>/dev/null
      printf 'source-file ~/%s\n' "$_tf" \
        >"$T/conf-tmux-parent/tmux/tmux.conf"
      _o=$(_inst) || fail "install errored on the tilde form [$_tf]"
      case $(_sr) in
      *'mux agent-render'*) ;;
      *) fail "a config written with a TILDE [$_tf] was not recognised, so
the reload never fires on a real machine: status-right is [$(_sr)]" ;;
      esac
    done
    tmux_drop_socket default
  fi
fi

# --- THE INSTALL ADOPTS LIVE AGENT RECORDS, ONCE -------------------------
# WHY HERE AND NOT IN THE LIB: the install is the only moment atomic with the
# writer switching over. `mux_agent_dir` did this for one afternoon and the
# measured cost was a session stuck reading `working` with an epoch 51 minutes
# stale, because a READER that migrates takes a snapshot and the old writer
# kept going. mux-agent-rank.t holds the other half (that the lib touches
# nothing); this holds the half that has to still work.
_old=$XDG_RUNTIME_DIR/agent-state/global
_new=$XDG_RUNTIME_DIR/mux/agent-state/global
mkdir -p "$_old" "$_new"
agent_rec "$_old/1" working %1 100 moving      # no destination: moves
agent_rec "$_old/2" working %2 100 superseded  # destination exists: kept
agent_rec "$_new/2" idle    %2 900 superseded
run install >"$T/aout" 2>&1 || fail "install errored: $(cat "$T/aout")"

grep -q 'moving' "$_new/1" 2>/dev/null \
  || fail "a record with no counterpart was not adopted, so every live pane
draws the no-record glyph until its agent's next lifecycle hook"
[ ! -e "$_old/1" ] || fail "the adopted record was COPIED, not moved. Two
copies and only one reader is how the stale-working bug happened"

# THE SUPERSEDED ONE KEEPS THE NEW PATH'S CONTENT, and no timestamp rule is
# applied: a beat refreshes mtime without advancing the epoch, so the stale
# copy can legitimately be the NEWER file. The installer therefore declines
# to judge and names the verb that can.
grep -q 'idle' "$_new/2" || fail "the installer overwrote a record already at
the new path. It cannot tell a snapshot from a live record, so it must not try"
[ ! -e "$_old/2" ] || fail "the superseded old record was left behind"
grep -q 'agent-doctor --repair' "$T/aout" \
  || fail "a kept record was not reported with its remedy: $(cat "$T/aout")"

# THE OLD TREE IS GONE, which is what stops a second install finding it again,
# and `rmdir` is what makes that safe: it refuses a directory still holding
# something, so anything unrecognised is kept rather than destroyed.
[ ! -e "$XDG_RUNTIME_DIR/agent-state" ] \
  || fail "the old state tree survived: $(ls -A "$XDG_RUNTIME_DIR/agent-state")"

# IDEMPOTENT, and silent the second time: nothing to adopt is not news.
run install >"$T/aout2" 2>&1 || fail "second install errored"
grep -q 'adopted' "$T/aout2" && fail "the install claimed an adoption with no
old path present: $(cat "$T/aout2")"
grep -q 'moving' "$_new/1" \
  || fail "a second install disturbed an adopted record"

# --- A VENV INSIDE THE PAYLOAD SURVIVES A RESTAGE ------------------------
# WHY THIS IS NOT HYPOTHETICAL: the indicator's venv folds into the payload,
# the swap REMOVES the old payload, and the two steps are separate modules in
# a provisioner. So a core install alone (every sweep that does not also touch
# the notifier) destroyed the venv and left `bin/mux-desktop-notifier`
# pointing at
# nothing, with `mux check` unable to say so because the indicator is a
# different package.
#
# MOVED RATHER THAN COPIED, so the swap stays atomic over a tree that is tens
# of megabytes; `_place-conversion.md` names hush's version as the one to copy
# and this is it.
mkdir -p "$_pay/venv/bin"
printf '#!/bin/sh\necho venv\n' >"$_pay/venv/bin/mux-desktop-notifier"
chmod +x "$_pay/venv/bin/mux-desktop-notifier"
printf 'carried\n' >"$_pay/venv/marker"
run install >"$T/vout" 2>&1 || fail "install errored: $(cat "$T/vout")"
[ -x "$_pay/venv/bin/mux-desktop-notifier" ] \
  || fail "the restage destroyed the payload's venv, so the indicator's unit
and its bin link now point at nothing until something rebuilds it"
grep -qx carried "$_pay/venv/marker" \
  || fail "the venv was recreated rather than carried, which loses whatever
was installed into it"

# AND THE PAYLOAD IS STILL FRESH AROUND IT: carrying the venv must not carry
# anything else, or a deleted file would survive forever.
[ ! -e "$_pay/stale-probe" ] || fail "a planted stale file survived"
printf 'x\n' >"$_pay/stale-probe"
run install >/dev/null 2>&1 || fail "install errored with a stale file"
[ ! -e "$_pay/stale-probe" ] \
  || fail "the restage kept a file that is not in the repo, so the payload is
no longer a copy of exactly the shipped tree"
[ -x "$_pay/venv/bin/mux-desktop-notifier" ] || fail "the venv went with it"

# --- THE NOTICES REACH THE LOG, AND ONLY AS EVENTS ------------------------
# WHY: measured 2026-10-01, a provisioner swallows this script's output
# entirely, so its log held one line of its own about mux and NOT ONE of
# mux's notices. Everything here exists to be read by a human, and on the
# fleet's only real install path nobody could.
_log=$MUX_STATE/mux.log
[ -f "$_log" ] || fail "the install logged nothing, so every notice it
printed exists only on a stdout that a provisioner throws away"
grep -q "installed .* to $_pay" "$_log" \
  || fail "the install EVENT is not logged, so nothing on the box can say
which mux it received or when. That has twice had to be reconstructed from a
payload mtime against a provisioner log: [$(cat "$_log")]"
grep -q 'agent-doctor --repair' "$_log" \
  || fail "the adoption kept a record unjudged and said so only on stdout.
That is the one notice here no later check can reconstruct, because the
adoption happens once: [$(cat "$_log")]"

# THE EVENT, NOT THE PROSE, and the pair is what makes this non-vacuous: the
# fragment notice DID fire and its wrapped explanation DID reach the
# terminal, so the log's silence about it is a choice rather than an absence.
# A log capped at mutations-and-failures volume must not fill with
# explanation, and prose copied into it is a second copy that can drift.
grep -q 'source-file' "$T/aout2" \
  || fail "the fragment notice did not fire, so the next assertion would
prove nothing: [$(cat "$T/aout2")]"
if grep -q 'source-file' "$_log"; then
  fail "a notice's continuation prose reached the log. The log records the
CONDITION and the terminal explains it; mux check already reports this one
durably, which is why it is deliberately not logged: [$(cat "$_log")]"
fi

# --- UNINSTALL REMOVES CODE, KEEPS YOUR FILES, AND SAYS WHICH ------------
# Keeping config, state and cache is right: a session set and a log are not
# the package's to delete. Saying NOTHING about them is not, because
# "uninstalled" then reads as "gone" while they sit on disk.
run uninstall >"$T/uout" 2>&1 || fail "uninstall errored"
[ -e "$T/bin/mux" ] && fail "bin/mux link not removed"
[ -e "$T/libexec/mux" ] && fail "libexec/mux link not removed"
[ -e "$T/share/mux" ] && fail "the payload tree was not removed"
grep -qi 'KEPT your own files' "$T/uout" \
  || fail "uninstall said nothing about what it kept: $(cat "$T/uout")"
grep -q 'config' "$T/uout" \
  || fail "uninstall did not NAME the config root it left behind:
$(cat "$T/uout")"

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

# --- AN ARGUMENT PAST THE VERB IS REFUSED, NEVER IGNORED -------------------
# FOUND BY MAKING THE MISTAKE on a live box: `sh setup.sh install
# PREFIX=/var/tmp/scratch` installed to the REAL prefix and printed its usual
# success line, because PREFIX is an ENVIRONMENT variable and `$2` was never
# read. The verb dispatch had always refused an unknown VERB; nothing looked
# at an unknown argument after a known one. It retargeted a deployed install
# and reloaded a live tmux server.
#
# THE LOAD-BEARING ASSERTION IS THE ABSENCE OF AN INSTALL, not the message: an
# error path that refuses AFTER acting is the defect, and a message proves
# only that something was said. Driven against its own FRESH prefix so
# "nothing was written" is a fact about this case rather than about whatever
# the cases above left behind.
_rp=$T/refuse
_o=$(env PREFIX="$_rp" XDG_BIN_HOME="$_rp/bin" XDG_DATA_HOME="$_rp/share" \
  NO_COLOR=1 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  sh "$HERE/setup.sh" install "PREFIX=$_rp" 2>&1) && _rc=0 || _rc=$?
[ "$_rc" -eq 2 ] || fail "a setting passed as an ARGUMENT must be refused with
2, got $_rc: [$_o]"
[ ! -d "$_rp" ] || [ "$(ls -A "$_rp" 2>/dev/null | wc -l)" -eq 0 ] \
  || fail "it refused and installed anyway, into [$_rp]: [$(ls -A "$_rp")].
An installer that writes after refusing is the whole defect; the message is
not the point."
# THE SETTING GETS ITS OWN MESSAGE, because a bare "unexpected argument" leaves
# the caller guessing which form is wanted, and prescribing the remedy is this
# fleet's rule for any refusal a human will hit.
case $_o in
*"is a SETTING"*) ;;
*) fail "the refusal did not say that a VAR=value argument is a setting, so
the caller is left to guess: [$_o]" ;;
esac
case $_o in
*"sh setup.sh install"*) ;;
*) fail "the refusal did not PRESCRIBE the environment form it wants: [$_o]" ;;
esac

# A PLAIN EXTRA ARGUMENT IS REFUSED TOO, and names both the argument and the
# verb it followed, which is what tells a caller it was not the verb at fault.
_o=$(run check extra 2>&1) && _rc=0 || _rc=$?
[ "$_rc" -eq 2 ] || fail "an extra argument after a known verb must exit 2,
got $_rc: [$_o]"
case $_o in
*"unexpected argument 'extra'"*) ;;
*) fail "the refusal did not name the offending argument: [$_o]" ;;
esac

# AND THE ONE VERB THAT TAKES MORE STILL DOES. `indicator` passes a verb and
# its flags through to the sub-package, so the guard must exempt it: this is
# the half a blanket arity check would break, and it would break the path a
# provisioner uses rather than one a human types.
_o=$(run indicator check 2>&1) && _rc=0 || _rc=$?
case $_o in
*"unexpected argument"*|*"is a SETTING"*)
  fail "the arity guard swallowed the indicator passthrough, which is the one
verb that legitimately takes another: [$_o]" ;;
esac

pass
