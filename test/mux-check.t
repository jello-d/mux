#!/bin/sh
# test/mux-check.t - `mux check`, the install audit.
#
# It is the thing you run to find out whether mux is coherently installed, so
# it being wrong is worse than most bugs: it does not merely fail, it tells you
# everything is fine. Its contract is small and exact:
#
#   one [OK]/[WARN]/[FAIL] line per check, and a NON-ZERO exit on any [FAIL]
#,
# and the second half is the part with teeth, because anything gating on
# mux check reads the exit code, not the text. A check that could print [FAIL]
# without setting it made the auditor itself assert something untrue.
#
# Everything runs against a scratch MUX_SHARE/MUX_DIR with a reduced PATH, so
# the real install is never consulted and nothing outside T is touched.
set -eu
_name=mux-check
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/share" "$T/conf/partitions" "$T/src"
cp -R "$HERE/share/." "$T/share/"
# The tmux stub answers list-keys and show-options from FILES, so one case can
# present a BROKEN server without any other case inheriting it. With the files
# absent it prints nothing and exits 0, which is what every case before the
# tmux-state section expects (and what "no server attached" looks like).
KEYS=$T/keys; SROPT=$T/sropt; SLOPT=$T/slopt; HOOKS=$T/hooks
PANES=$T/panes
export KEYS SROPT SLOPT HOOKS PANES
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
# NO SERVER IS AN EXIT CODE, not empty output, which is how the real tool says
# it: `tmux list-sessions` ERRORS when nothing is running, and `list-keys`
# cheerfully STARTS a server and answers from tmux's defaults. mux-check
# therefore probes with list-sessions, so this arm has to fail the same way or
# the stub is looser than the tool and the no-server case passes for the wrong
# reason. Keyed on $KEYS, so one fixture still presents one whole server.
# A MORE SPECIFIC ARM FIRST, because the two questions are different: the
# BARE call is the no-server probe and answers with an exit code only, while
# `-F` asks for the session NAMES. One arm serving both would have made the
# name audit read an empty list and pass for the wrong reason.
*"list-sessions -F"*)              [ -f "$KEYS" ] || exit 1
                                   [ -f "$SESSN" ] && cat "$SESSN" ;;
*list-sessions*)                   [ -f "$KEYS" ] || exit 1 ;;
*list-keys*)                       [ -f "$KEYS" ]  && cat "$KEYS" ;;
*list-panes*)                      [ -f "$PANES" ] && cat "$PANES" ;;
*"show-options -gv status-right"*) [ -f "$SROPT" ] && cat "$SROPT" ;;
*"show-options -gv status-left"*)  [ -f "$SLOPT" ] && cat "$SLOPT" ;;
# FILTERED BY THE HOOK ASKED FOR, like the real thing. Returning the whole
# file whatever was requested made a "missing hook" case pass, because some
# OTHER hook's line mentioned mux and the grep found it.
*show-hooks*) [ -f "$HOOKS" ] && { for _a in "$@"; do :; done
              grep "^$_a" "$HOOKS" 2>/dev/null || true; } ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/mux";  chmod +x "$T/bin/mux"
# Everything mux-check shells out to. A reduced PATH is the point (the
# notification checks below turn backends on and off by their PRESENCE), so
# the ordinary tools have to be put back explicitly.
for _c in sed awk grep cut tr head tail wc cat ls id date find sort \
    basename dirname mktemp rm mkdir cp mv readlink; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
# Partition `probe`, NOT `global`: mux resolves MUX_DIR over MUX_SHARE, so
# deleting an overlay global.partition falls back to the SHIPPED one and the
# audit reads the real ~/src. A name nothing ships has no fallback to hide
# behind, which is what lets the no-scan-roots case be tested at all.
printf '#!/bin/sh\necho probe\n' >"$T/conf/cc"; chmod +x "$T/conf/cc"
printf 'context-command cc\n' >"$T/conf/config"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# check [ENV=VAL ...] -> the audit's output; RC holds its exit status.
check() {
  OUT=$(env \
    PATH="$T/bin" NO_COLOR=1 MUX_DIR="$T/conf" SESSN="$T/sessn" \
    MUX_SHARE="$T/share" MUX_CACHE="$T/cache" \
    "$@" "$HERE/libexec/mux-check" 2>&1) && RC=0 || RC=$?
  printf '%s' "$OUT"
}
has() { case "$OUT" in *"$1"*) ;; *) fail "$2: want [$1] in:
$OUT" ;; esac; }
no_has() { case "$OUT" in *"$1"*) fail "$2: unwanted [$1] in:
$OUT" ;; esac; }

# --- a healthy install: every marker OK, exit 0 ---------------------------
check >/dev/null
[ "$RC" -eq 0 ] || fail "a healthy install exited $RC:
$OUT"
no_has "[FAIL]" "healthy install reported a FAIL"
has "tmux present" "no tmux line"
has "package data" "no package-data line"
has "config overlay" "no overlay line"
has "scan root $T/src" "the configured scan root was not checked"
has "agent instructions assemble" "the skill was not checked"

# --- A PARTIAL SKILL INSTALL IS A FAIL, not an OK -------------------------
# The document is a body plus a frontmatter file, and a skill emitted WITHOUT
# the frontmatter installs cleanly, errors nothing and then never triggers,
# so `share/skills` being present is not the question. This is the case a
# presence check passes and the reason the marker runs the thing.
mv "$T/share/skills/mux-agent/frontmatter.yaml" "$T/fm.stash"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a skill that cannot be assembled exited 0:
$OUT"
has "[FAIL]" "a partial skill install did not FAIL"
has "cannot assemble" "the FAIL did not say what was wrong:
$OUT"
mv "$T/fm.stash" "$T/share/skills/mux-agent/frontmatter.yaml"
check >/dev/null
[ "$RC" -eq 0 ] || fail "restoring the frontmatter did not restore health:
$OUT"

# --- a FAIL must set the exit code ----------------------------------------
# Each of these is raised from a DIFFERENT part of the file, which is the
# point: the scan-root check ran inside a `while` behind a pipe, so its RC=1
# was set in a subshell and discarded. It printed [FAIL] and exited 0.
check MUX_SHARE="$T/nosuchshare" >/dev/null
[ "$RC" -ne 0 ] || fail "missing package data exited 0"
has "[FAIL]" "missing package data raised no FAIL"

rm -rf "$T/src"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing scan root printed FAIL but exited 0"
has "scan root missing" "no report of the missing root"
# ... and it is still reported per-root, not collapsed to the first.
printf 'scan %s/src 2\nscan %s/other 2\n' "$T" "$T" \
  >"$T/conf/partitions/probe.partition"
check >/dev/null
[ "$RC" -ne 0 ] || fail "two missing roots exited 0"
has "$T/src" "first missing root unreported"
has "$T/other" "second missing root unreported"
mkdir -p "$T/src" "$T/other"
check >/dev/null
[ "$RC" -eq 0 ] || fail "both roots present, still exited $RC"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# --- a broken install is a FAIL, not a warning ----------------------------
mv "$T/share/layouts" "$T/share/layouts.away"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing share/layouts exited 0"
has "share/layouts missing" "no report of the missing share dir"
mv "$T/share/layouts.away" "$T/share/layouts"

# --- WARN is advisory: it reports, it does not fail -----------------------
# The distinction is the whole value of three markers rather than two.
printf 'root=%s\n' "$T" >"$T/conf/old.layout"
check >/dev/null
has "pre-rename" "a pre-rename *.layout was not surfaced"
has "mux migrate-profiles" "no pointer to the fix"
[ "$RC" -eq 0 ] || fail "a WARN must not fail the audit (rc=$RC)"
rm -f "$T/conf/old.layout"

# A name in BOTH the profile table and profiles.d is drift, and advisory.
mkdir -p "$T/conf/profiles.d"
printf 'dup root=%s\n' "$T/src" >"$T/conf/profiles"
printf 'root %s\n' "$T/src" >"$T/conf/profiles.d/dup.profile"
check >/dev/null
has "both a row and a breakout" "the row/file collision was not surfaced"
[ "$RC" -eq 0 ] || fail "a drift WARN must not fail the audit"
rm -rf "$T/conf/profiles" "$T/conf/profiles.d"

# --- A CONFIG DIRECTIVE MUX DOES NOT READ ---------------------------------
# MEASURED BEFORE THIS EXISTED: three mistyped keys and the audit said
# `[OK] config overlay` about all of them. Each one is INERT, which is the
# whole problem: `contextcommand` means no partitions, `latch-prob` means no
# probe, `env-redy` means nothing waits, and nothing anywhere says so.
#
# IT MATTERS MORE NOW A PROVISIONER MAY PLACE THIS FILE: a placed file is
# re-asserted every run and nobody reads it again, so a key renamed in a
# later mux sits there doing nothing for as long as the box lives.
_cfgsave=$T/conf/config.save
cp "$T/conf/config" "$_cfgsave"
printf 'context-command cc\nlatch-prob ssh-probe\n' >"$T/conf/config"
check >/dev/null
has "latch-prob" "a config key mux does not read went unreported, and an
inert directive is the worst kind: no error, no effect"
has "INERT" "the WARN does not say what the consequence is"
no_has "[FAIL]" "an unknown key must not FAIL the audit: \$MUX_DIR is shared
between machines and a key from a NEWER mux is a normal state, which is the
same reason _mux_ctx_merge ignores one in a settings file"
[ "$RC" -eq 0 ] || fail "an unknown config key failed the audit (rc=$RC)"

# AND A KEY MUX DOES READ IS NOT REPORTED, which is the control: a check that
# warned about everything would pass the assertion above while being useless.
# `latch-probe` is the near-miss of the key above, so this also proves the
# match is exact rather than a substring.
printf 'context-command cc\nlatch-probe ssh-probe\nenv-timeout 2\n' \
  >"$T/conf/config"
check >/dev/null
no_has "does not read" "a config of entirely VALID keys was reported as
unknown, so the legal set is not being read correctly"
has "all ones mux reads" "the pass line is missing, so this marker cannot be
told from one that stopped running"

# AND WITH NO SAMPLE TO READ IT SAYS SO rather than warning about every key.
# The legal set comes from share/config.sample, so an install without one (an
# older payload, or a MUX_SHARE pointing at a different tree, which is the
# state this box was in the first time this ran) cannot answer the question.
# Hedging beats a confident wrong answer about a config that is fine.
mv "$T/share/config.sample" "$T/share/config.sample.off"
check >/dev/null
has "cannot audit its keys" "with no config.sample the marker must HEDGE, not
report every directive as unknown"
no_has "does not read" "it warned about valid keys with no sample to check
them against"
mv "$T/share/config.sample.off" "$T/share/config.sample"
cp "$_cfgsave" "$T/conf/config"

# --- no scan roots at all: discovery is OFF, and says so ------------------
rm -f "$T/conf/partitions/probe.partition"
check >/dev/null
has "no scan roots" "silent about discovery being off"
has "discovery is off" "did not say what that means"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# --- notifications: the notifier, not notify-send ------------------------
# mux raises nothing itself now, so what this marker can honestly report
# changed with it: `notify-send` being on PATH says nothing about whether
# anything will ever raise a banner, because the thing that raises them is a
# separate package on the DESKTOP box. A box you only ever latch to has its
# banners raised where you are sitting, so a finding here would be a finding
# about every remote machine in the fleet.
# UNDER THE PINNED HOME, which is where the marker looks: it resolves
# `${MUX_DESKTOP_NOTIFIER_BIN:-$HOME/.local/bin}`, so planting the link on the
# curated PATH instead proves nothing. The first version did exactly that and
# reported a dangling link as absent, which is a fact about the fixture.
_nbd=$HOME/.local/bin
mkdir -p "$_nbd"
rm -f "$_nbd/mux-desktop-notifier"
# A BUS THAT ANSWERS, because without one the marker correctly says it cannot
# tell and the finding never fires: measured, the sandbox has no gdbus, so the
# first version of this asserted a WARN against the "no bus to ask from here"
# arm and failed for a reason that had nothing to do with the notifier. That
# hedge is deliberate (a box you only latch to must not report a finding about
# every machine in the fleet), so a test about the finding has to supply the
# bus the finding needs.
cat >"$T/bin/gdbus" <<'GD'
#!/bin/sh
case "$*" in
*NameHasOwner*)          printf '(false,)\n' ;;
*ListActivatableNames*)  printf "([''],)\n" ;;
esac
exit 0
GD
chmod +x "$T/bin/gdbus"
check >/dev/null
has "no desktop notifier here" "a missing notifier was not reported"
[ "$RC" -eq 0 ] || fail "an absent notification path must not FAIL: it is
optional, and a provisioner's apply cannot install somebody's desktop"

# AND IT IS CREDITED WHEN PRESENT. Asserted on a DANGLING symlink, which is
# the state a rename or a removed venv leaves behind: `-e` follows a symlink
# and answers false for one, so a check testing only `-e` would read
# "installed and broken" as "never installed" and send you to install
# something that is already there.
ln -sfn "$T/nowhere/mux-desktop-notifier" "$_nbd/mux-desktop-notifier"
check >/dev/null
case $OUT in
*"no desktop notifier here"*) fail "a dangling notifier link read as absent,
so the one state a rename leaves behind is the one this cannot see" ;;
esac
# `notify-send` IS NO LONGER PART OF THE QUESTION, and its absence being
# silent is the assertion worth keeping from the case that used to live here:
# mux does not raise banners, so a box without libnotify installed is not a
# box with a mux problem. Reporting on it would be a finding about somebody
# else's package.
rm -f "$T/bin/notify-send"
check >/dev/null
case $OUT in
*notify-send*) fail "the check still reports on notify-send, which mux no
longer uses: the notifier raises banners now and does it over the bus" ;;
esac

# --- ... AND A THIRD HALF: can anything actually DISPLAY one? -------------
# THIS MARKER SAID [OK] ON A BOX WHERE NOTIFICATIONS FAILED OUTRIGHT, which
# is the marker contract broken inside the file that defines it: notify-send
# was present, no daemon owned the name, and every notification died with
# `Message recipient disconnected from message bus without replying`.
#
# The stub answers the BUS's NameHasOwner, which is what mux asks. Driven in
# all three directions because they are three different bugs, and the middle
# one is the bug that was shipped.
#
# ONE ARM PER QUESTION. mux asks the bus TWO things now (who owns the name,
# and which names can be ACTIVATED), and a stub answering both the same way
# is looser than the tool: `(false,)` to the second question happens to parse
# as "not activatable", so the old single-answer stub kept the first case
# green while being unable to express the new one at all.
_bus() {   # <owner-reply-or-empty> [activatable-list]
  printf '%s' "${1:-}" >"$T/bus-owner"
  printf '%s' "${2:-}" >"$T/bus-act"
  for _bt in gdbus busctl dbus-send; do
    cat >"$T/bin/$_bt" <<EOF
#!/bin/sh
case \$* in
*ListActivatableNames*) cat "$T/bus-act"; echo; exit 0 ;;
esac
[ -s "$T/bus-owner" ] || exit 1
cat "$T/bus-owner"; echo
EOF
    chmod +x "$T/bin/$_bt"
  done
}

_bus '(false,)' "([ 'org.freedesktop.DBus' ],)"
check >/dev/null
has "NOTHING DISPLAYS them" "a bus that says NOBODY owns the notification
name means mux can raise and nothing will show it, which is the 'fully
installed and fully broken' state this whole contract exists to catch"
[ "$RC" -eq 0 ] || fail "which notification daemon runs is the user's
desktop rather than mux's install, and a provisioner's apply cannot repair
it, so this is a WARN and must never FAIL the audit"

# --- NOBODY HOME IS NOT NOBODY COMING -------------------------------------
# The name is D-Bus ACTIVATABLE, so the first notification starts a daemon.
# Measured five minutes after a real reboot: unowned, no mako running, the
# name listed, and notifications working perfectly. Warning there was this
# check being wrong in the OPPOSITE direction to the bug it was added for,
# and it is the ordinary state of every box for its first minutes.
_bus '(false,)' "([ 'org.freedesktop.DBus', 'org.freedesktop.Notifications' ],)"
check >/dev/null
no_has "NOTHING DISPLAYS them" "the name is ACTIVATABLE, so a daemon starts
on the first notification: warning that nothing will display one is a false
finding about a box that works, and it is what every box looks like for the
first minutes after a boot"
has "start one on demand" "the hedge has to be SAID: an [OK] here is not the
same fact as an [OK] backed by a daemon that is already up"
[ "$RC" -eq 0 ] || fail "an activatable name is not a failure"

# AND THE MATCH IS QUOTE-EXACT, which is this control's whole reason: this
# box also lists `org.gnome.Shell.Notifications`, so a substring match would
# read a GNOME service as an answer about ours and silence the one real
# warning in the set.
_bus '(false,)' "([ 'org.gnome.Shell.Notifications' ],)"
check >/dev/null
has "NOTHING DISPLAYS them" "a name that merely CONTAINS ours is a different
service, and crediting it turns the one real finding here into silence"

_bus '(true,)' "([ 'org.freedesktop.Notifications' ],)"
check >/dev/null
has "a live daemon" "a daemon that DOES own the name must be credited, or
the marker is just as uninformative in the other direction"
no_has "NOTHING DISPLAYS them" "a live daemon was reported as no daemon"

# THE LOAD-BEARING ONE: the question could not be PUT. `mux check` over ssh
# reaches no session bus at all, and reporting the desktop broken from a
# context that cannot see it is exactly the false finding the WAYLAND_DISPLAY
# validator shipped this week. Asserted as an ABSENCE, because the bug here
# would be an extra warning rather than a missing one.
_bus '' ''
check >/dev/null
no_has "NOTHING DISPLAYS them" "with no bus to ask, mux must not claim
nothing will display a notification: that is a confident false finding about
a machine that is very likely fine"
has "no bus to confirm" "the hedge has to be SAID, or an [OK] here is
indistinguishable from one backed by a real live daemon"
[ "$RC" -eq 0 ] || fail "being unable to ask is not a failure"
_bus '(true,)' "([ 'org.freedesktop.Notifications' ],)"

# AND THE OLD OVERRIDE PAIR IS NOT CONSULTED. `MUX_NOTIFY_SEND` and
# `MUX_NOTIFY_CLOSE` are gone: they had no caller once the raising moved, and
# a seam nobody crosses is not a seam. Asserted because a check still reading
# them would credit an override that does nothing, which is worse than not
# offering one: the user would believe they had redirected their banners.
check MUX_NOTIFY_SEND=true MUX_NOTIFY_CLOSE=true >/dev/null
case $OUT in
*overridden*) fail "the check credited a retired override pair, so a user
setting it would believe their notifications had been redirected" ;;
esac

# --- the product WORKING, not merely installed ----------------------------
# Everything above is a presence check: files exist, commands resolve, config
# parses. Asked the only question that matters (what would this say about a
# box that is fully installed and fully BROKEN?), the answer used to be [OK]
# to every line. That is not a thought experiment: a box ran for days with the
# strip wrong about six of seven sessions while this audit reported clean.
#
# So these assert what tmux is actually configured to do. Read-only queries by
# design: the check must never run `mux agent-render`, which PRUNES state files
# and has deleted every agent's state when pointed at the wrong socket.

# A server with tmux's DEFAULT bindings and nothing of mux's. Note `(` IS bound
# by default (switch-client -p), which is the trap: testing that the KEY exists
# would pass here. What must be asserted is that it runs a mux verb.
cat >"$KEYS" <<'EOF'
bind-key    -T prefix (       switch-client -p
bind-key    -T prefix )       switch-client -n
bind-key    -T prefix b       send-prefix
bind-key    -T prefix r       refresh-client
bind-key    -T prefix R       respawn-pane
EOF
: >"$SROPT"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a server with no mux config exited 0"
has "key binding(s) not bound to mux" "broken bindings were not reported"
has "status-right is empty" "an empty status-right was not reported"

# Broken bindings must fail the audit ON THEIR OWN. Asserting a non-zero exit
# while status-right was ALSO broken proved nothing about the bindings: either
# failure set it. Caught by mutation: downgrading the binding [FAIL] to a
# [WARN] left the suite green, because the other failure was carrying the exit
# code. So here status-right is CORRECT and the bindings are the only fault.
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"
printf '#(mux style #S #{pane_pid})#[bold]#S\n' >"$SLOPT"
check >/dev/null
has "key binding(s) not bound to mux" "broken bindings alone were not reported"
# "status-right is ..." is the FAILURE wording; "status-right draws ..." is
# the healthy one. Matching the bare option name hits both.
no_has "status-right is" "status-right was wrongly implicated"
[ "$RC" -ne 0 ] || fail "broken bindings alone must fail the audit"
: >"$SROPT"

# ... and a status-right that is set but is somebody ELSE's job is just as
# broken: the bar still renders, minus the only thing mux exists to show, so it
# reads as "no agents are running" rather than as a fault.
printf '#(date)\n' >"$SROPT"
check >/dev/null
has "status-right is not mux's renderer" "a foreign status-right passed"

# A healthy server: every binding reaches a mux verb, both status jobs are ours.
# BUILT FROM share/mux.tmux, not typed. A hand-written fixture here is the
# same mistake the check itself was making: this file listed ( ) b r R while
# the fragment had also bound u and E, so the test would have gone on passing
# a server missing both: asserting a green check against a stale idea of
# what green means.
# ANY bind whose command mentions mux, matching what the check now derives.
# The narrower `run-shell` pattern missed `prefix ?` (a `display-popup`) the day
# it was added, on BOTH sides, so the check stopped expecting it and this
# fixture stopped providing it, and the two agreed with each other about a key
# neither was looking at. Both patterns move together or the agreement is
# worthless.
_healthy_keys() {
  : >"$KEYS"
  sed -n 's/^bind \([^ -][^ ]*\) .*"\(mux [^"]*\)".*$/\1 \2/p' \
    "$HERE/share/mux.tmux" | while read -r _k _cmd; do
    printf 'bind-key    -T prefix %s       run-shell "%s"\n' \
      "$_k" "$_cmd"
  done >>"$KEYS"
}
_healthy_keys
# Every hook the fragment installs, as tmux would report it. A FUNCTION, so
# the cases below can put the server back: this file's own rule is that one
# case must never leave a broken server for the next to inherit.
_healthy_hooks() {
  : >"$HOOKS"
  sed -n 's/^set-hook -[ag]* \([a-z-]*\) .*/\1/p' \
    "$HERE/share/mux.tmux" | sort -u | while read -r _h; do
    printf '%s[0] run-shell -b "mux pin"\n' "$_h"
  done >>"$HOOKS"
}
_healthy_hooks
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"
printf '#(mux style #S #{pane_pid})#[bold]#S\n' >"$SLOPT"
check >/dev/null
has "key bindings live" "a correctly bound server was not recognised"
has "status-right draws the agent strip" "a correct status-right was not seen"
has "status-left draws the session chip" "a correct status-left was not seen"
no_has "not bound to mux" "a healthy server reported broken bindings"
has "tmux hooks live" "a correctly hooked server was not recognised"

# --- AN AGENT MUX STARTED AND HAS NEVER HEARD FROM ------------------------
# The first-run failure, and the one a presence check cannot see: everything is
# installed, the strip draws, and every chip reads the same as a plain shell
# because nothing ever told the agent to report. The GLYPH says something is
# wrong; this says what, and names the fix.
#
# A WARN, not a FAIL: the agent's own config is the user's, a provisioner's
# `apply` cannot repair it, and `--no-agent` is a deliberate reason to have no
# agent at all. Advisory is the honest level.
# TWO FIELDS, because that is what the CHECK asks tmux for
# (`#{@mux-agent}\t#{session_name}`): it needs no pane ids, unlike the strip.
# The stub answers from a file whatever format was requested, so each fixture
# has to match its own consumer.
printf '1\tunwired-sess\n' >"$PANES"
check >/dev/null
has "no agent state from: unwired-sess" "a session with an agent pane and no
record was not reported, so the only sign of unwired hooks is a glyph that
looks exactly like a plain shell"
has "mux setup" "the WARN did not name the command that fixes it; a gap named
without a remedy invites two different fixes"
no_has "[FAIL]" "an unwired agent must not FAIL the check, which a provisioner
reads as drift its apply can repair, and it cannot"

# ... and the healthy case SAYS SO, because a check that is silent on success
# cannot be told from one that never ran. (No marker, so mux started no agent.)
printf '\tplain-sess\n' >"$PANES"
check >/dev/null
has "every agent session has reported" "the healthy case is silent"
rm -f "$PANES"

# --- A SERVER CARRYING AN OLDER SET OF BINDINGS ---------------------------
# The exact live failure, and the one a hardcoded list cannot see: the server
# has the bindings it was started with, the FRAGMENT has gained more. This
# check listed `( ) b r R` by hand while mux.tmux had also bound u (0.43) and
# E (0.50), so a server missing both reported clean for two releases.
#
# Asserted by dropping whatever the fragment binds BEYOND that old five, so
# the case keeps working as more are added rather than pinning today's set.
grep -vE '^bind-key +-T prefix [uE] ' "$KEYS" >"$KEYS.t"
mv "$KEYS.t" "$KEYS"
check >/dev/null
has "not bound to mux" "a server missing the newer bindings passed clean:
the wanted list is hardcoded, so it cannot notice a binding the fragment
gained after it was written"
_healthy_keys

# --- A STALE SERVER AND AN UNSOURCED ONE GET DIFFERENT REMEDIES -----------
# The common case by far is a LIVE server whose tmux.conf already sources the
# fragment but which started before a binding existed: sourcing a file does not
# reload a running server. Telling that user "the fragment is not sourced" is
# advice that CANNOT COME TRUE (the line is already there), and a provisioner
# reading it loops forever applying a fix that changes nothing. tackup reported
# exactly that after `prefix ?` was added: "APPLY DID NOT FIX ... a fix owed by
# another repo".
#
# The discriminator is on the server: status-right being mux's renderer proves
# the fragment HAS been sourced here.
_healthy_keys
grep -v 'prefix ?' "$KEYS" >"$KEYS.t"; mv "$KEYS.t" "$KEYS"
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"
check >/dev/null
has "mux reload" "a server that has mux's strip but is missing a NEW binding is
STALE, and the only thing that fixes it is a reload. Saying 'the fragment is not
sourced' sends a provisioner into a loop applying a line that is already there."
no_has "the fragment is not sourced" "the stale case was given the unsourced
case's remedy, which is the bug this pair exists to prevent"

# ... and the genuinely unsourced case still gets the source-file line. Both
# directions, because one message covering both is how this went wrong.
: >"$SROPT"
check >/dev/null
has "the fragment is not sourced" "a server with neither mux's bindings nor
mux's status-right has never sourced the fragment, and that is the one case
where adding the line is the fix"
no_has "mux reload" "an unsourced server was told to reload, which would do
nothing: there is no fragment in its config to re-read"
_healthy_keys
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"

# --- A HOOK THE SERVER NEVER GOT ------------------------------------------
# The failure that was invisible for two releases: installing mux.tmux does
# NOT reload a running server, so a tmux up since before a feature landed
# keeps running without its hooks while every other marker stays green.
# Measured live on 2026-09-27: `prefix u` and the whole
# window-layout-changed set were absent and this check said nothing.
grep -v '^window-layout-changed' "$HOOKS" >"$HOOKS.t"; mv "$HOOKS.t" "$HOOKS"
check >/dev/null
has "tmux hook(s) missing" "a server missing a hook passed clean"
has "mux reload" "the fix was not named"

# ... and a hook that EXISTS but is somebody else's is not ours either, the
# same reasoning the binding check already uses.
printf 'window-layout-changed[0] run-shell "something-else"\n' >>"$HOOKS"
check >/dev/null
has "tmux hook(s) missing" "a foreign hook was accepted as mux's"
_healthy_hooks                  # ... and hand the next case a sound server

# status-left is cosmetic, so its absence is a WARN and must NOT fail the run.
printf '#S\n' >"$SLOPT"
check >/dev/null
has "status-left is not mux's" "a foreign status-left was not surfaced"
no_has "[FAIL]" "a cosmetic status-left was escalated to a failure"
[ "$RC" -eq 0 ] || fail "a cosmetic status-left must not fail the run"
printf '#(mux style #S #{pane_pid})#[bold]#S\n' >"$SLOPT"

# NO server is a healthy state (a fresh boot, a headless box), so it must not
# fail, but it is said OUT LOUD, because a check that silently skips its only
# functional assertions is precisely the check this section replaces.
rm -f "$KEYS"
check >/dev/null
has "tmux state unchecked" "a skipped tmux-state check was silent"
[ "$RC" -eq 0 ] || fail "no tmux server must not fail the audit"

# --- two mux commands on PATH is the banned state -------------------------
# The earlier entry silently shadows the later one and then rots behind it.
# Nothing else here can see it: every other check follows the copy it is
# already running from, so the shadowed install audits itself and passes.
mkdir -p "$T/bin2"
printf '#!/bin/sh\nexit 0\n' >"$T/bin2/mux"; chmod +x "$T/bin2/mux"
OUT=$(env \
  PATH="$T/bin2:$T/bin" NO_COLOR=1 MUX_DIR="$T/conf" \
  MUX_SHARE="$T/share" MUX_CACHE="$T/cache" \
  "$HERE/libexec/mux-check" 2>&1) && RC=0 || RC=$?
has "2 mux commands on PATH" "a shadowing second mux was not reported"
has "$T/bin2/mux" "the shadowing copy was not named"
has "$T/bin/mux" "the shadowed copy was not named"
[ "$RC" -ne 0 ] || fail "two mux commands on PATH must fail the audit"
rm -rf "$T/bin2"
check >/dev/null
no_has "mux commands on PATH" "one mux on PATH was reported as several"

# --- A SESSION MUX CANNOT ADDRESS ----------------------------------------
# mux RESERVES the colon in a session name: every verb refuses to create one
# and every derived name folds it. A session made with RAW tmux is the gap
# that leaves, and it only became reachable at all in tmux 3.7, which
# sanitises session names NOT AT ALL (3.4 and 3.6 fold a colon, 3.7c keeps
# every character). So this needs the STUB to be testable on a 3.6 box: the
# real tmux here will not make such a session, which is exactly why a
# platform-dependent premise has to be enforced by mux rather than hoped for.
# A SERVER MUST BE PRESENT, because this marker lives inside the tmux-state
# block: with no server the whole section is skipped and the case would pass
# while asserting nothing. My first version set only the names fixture and
# the audit reported `no tmux server ... tmux state unchecked`.
_healthy_keys
_healthy_hooks
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"
printf '#(mux style #S #{pane_pid})#[bold]#S\n' >"$SLOPT"
printf 'plain\nwork:api\n' >"$T/sessn"
check >/dev/null
has "cannot address" "a session whose name holds a colon cannot be named in
an address, and nothing else in this audit can see it"
has "work:api" "the WARN must NAME the session, since the remedy is to rename
that one and a count cannot say which"
no_has "[FAIL]" "an unaddressable session is the USER's to rename, not a
provisioner's, and nothing is broken by it: the session works and simply
cannot be qualified, so this must never fail the audit"
[ "$RC" -eq 0 ] || fail "an unaddressable session must not fail the audit"

# ... and a clean set says nothing at all, which is the half that stops this
# becoming noise on every run.
printf 'plain\nother\n' >"$T/sessn"
check >/dev/null
no_has "cannot address" "every session name is clean here, so the marker must
stay silent rather than reporting its own existence"


# --- ASSERTED VERSUS ACTUAL: THE RECORDED SET AND THE SERVER --------------
# `mux resume` rebuilds the SET and nothing else, so a live session missing
# from it is lost by the next reboot with nothing having said so. The two
# directions are deliberately NOT symmetric and each is asserted on its own,
# because one assertion that "they differ" would pass on either.
_SETF=$MUX_STATE/sessions.probe

# BOTH DIRECTIONS PRESENT AT ONCE, which is what makes the asymmetry
# observable: `two` is live and unrecorded, `gone` is recorded and not live.
printf 'one\ntwo\n' >"$T/sessn"
printf 'one\t/tmp\ngone\t/tmp\n' >"$_SETF"
check >/dev/null
has "two" "a live session absent from the set went unreported: a reboot loses
it, and the set is the only thing mux resume rebuilds"
no_has "[FAIL]" "an unrecorded session is drift rather than breakage: every
attach records, so it heals, and a provisioner must not fail over it"
[ "$RC" -eq 0 ] || fail "unrecorded sessions must not fail the audit"

# AND THE OTHER DIRECTION IS NOT A FINDING. mux sets no `session-closed` hook
# (measured: it fires on a kill-session, never on a kill-server, and never for
# the LAST session because the server exits first), so a session whose last
# pane took a stray ^D stays recorded for ever. That is the DESIGN, not drift:
# a ^D is one keystroke from detach, which is the whole reason `mux undo-pane`
# exists, so rebuilding it on the next resume is the wanted answer. Reporting
# it would make the marker cry wolf on an ordinary working day.
printf 'one\ntwo\n' >"$T/sessn"
printf 'one\t/tmp\ntwo\t/tmp\ngone\t/tmp\n' >"$_SETF"
check >/dev/null
# MATCHED ON THE MESSAGE AND NOT ON THE `[WARN]` PREFIX, which my first
# version got wrong and only a probe found: continuation lines are indented
# and the opening one is not, so a pattern carrying the prefix plus three
# spaces matched nothing and the assertion read as coverage. Every live
# session IS recorded in this case, so the whole WARN must be absent.
no_has "live but NOT" "a recorded session that is not up raised a WARN.
Nothing removes an entry when a session dies by any route other than
\`mux kill\`, so that state is reached by an accidental ^D and is exactly
what the set is for"
# ... and it is STATED anyway, because a marker printing a bare `ok` cannot be
# caught lying about what it measured. This is the half that answers "did
# resume come back short?" after the log has scrolled away.
has "resume would also rebuild" "the pass line does not say which recorded
sessions are not up, so the audit cannot be asked what it measured"
has "gone" "the pass line does not NAME the session, and the useful
post-mortem is always about the one that is missing"

# A SET THAT AGREES SAYS SO, WITH ITS COUNT. `ok` alone cannot be told from a
# marker that stopped matching, which is the 149-to-129 lesson this tree paid
# for in its own linter.
printf 'one\ntwo\n' >"$T/sessn"
printf 'one\t/tmp\ntwo\t/tmp\n' >"$_SETF"
check >/dev/null
has "session set agrees with the server" "an agreeing set is not reported, so
there is no way to tell the comparison ran from it having been removed"
has "2 live" "the agreeing line states no count, so a marker that stopped
seeing sessions would read identically to one that saw them all"

# READ-ONLY, WHICH IS THE CONTRACT THIS WHOLE FILE EXISTS FOR. `mux_sess_list`
# reaches `mux_state_path`, which ADOPTS a pre-0.38 copy by MOVING it out of
# the cache. A check that migrates is a check that damages what it inspects,
# and this package has already shipped that twice: `mux check` once spawned a
# tmux server to ask about bindings, and the agent-state directory adopted on
# a READ path and froze a live record for an hour.
rm -f "$_SETF"
mkdir -p "$T/cache"
printf 'cached\t/tmp\n' >"$T/cache/sessions.probe"
check >/dev/null
[ -f "$T/cache/sessions.probe" ] || fail "the audit MOVED the pre-0.38
session set out of the cache. A check must never be able to change what it
inspects, and the adoption belongs to a verb the user chose to run."
[ ! -f "$_SETF" ] || fail "the audit created the state copy of the session
set, so it performed the migration it must only observe"
rm -f "$T/cache/sessions.probe"


# --- tmux itself: the one hard runtime dependency -------------------------
rm -f "$T/bin/tmux"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing tmux exited 0"
has "tmux not found" "no report of the missing dependency"

# --- THE PROBE MUST NOT CREATE A SERVER, against a REAL tmux -------------
# The one case a stub cannot answer, and the reason it went unnoticed for the
# life of the check: `tmux list-keys` STARTS a server when none is running and
# answers out of tmux's DEFAULTS, so the old guard (is list-keys output empty?)
# could never conclude "no server". On a bare box `mux check` therefore SPAWNED
# one and then reported five FAILs about the pristine thing it had just made,
# exiting non-zero. Found on ubuntu-latest, which is the only bare box in this
# project's history.
#
# A STUB CANNOT SEE THIS because spawning is real tmux's behaviour, not the
# check's logic, which is the same lesson the stale-code check learned: a suite
# that stubs a seam to test the caller leaves the seam untested.
if command -v tmux >/dev/null 2>&1; then
  _sock=$(tmux_fresh_socket muxchk)
  _o=$(env -u TMUX -u TMUX_PANE -u MUX_SHARE NO_COLOR=1 \
    MUX_CTX_PARTITION="$_sock" MUX_DIR="$T/conf" \
    "$HERE/libexec/mux-check" 2>&1 || true)
  case $_o in
  *"no tmux server"*) ;;
  *) fail "with no server running, the check did not say so. Its honest
'tmux state unchecked' line is unreachable if the probe can create what it is
looking for, and every assertion below it then fails about a server the user
never started:
$_o" ;;
  esac
  # THE ASSERTION THAT MATTERS: a check may not mutate what it inspects, which
  # this file's own source says three lines above the line that did.
  if env -u TMUX tmux -L "$_sock" list-sessions >/dev/null 2>&1; then
    tmux_drop_socket "$_sock"
    fail "mux check STARTED a tmux server on '$_sock'. A check must never be
able to damage or create what it inspects, and the five FAILs it then reports
are about a server nobody asked for."
  fi
  tmux_drop_socket "$_sock"
fi

# --- a managed pointer that does not EXIST is a finding, not silence -------
# This marker used to collect `drop` verdicts only, so a name mux manages that
# resolved to NOTHING was listed among the healthy ones and the line read
# [OK]. That is precisely the state of a desktop box between booting and its
# graphical session starting, which is when a latch rebuilds every session, so
# the check called the environment healthy during exactly the window where it
# was not.
#
# THE FIXTURE PRODUCES IT FOR FREE: the curated PATH has no `systemctl` and no
# `env`, so nothing resolves any of the shipped names, which is the same shape
# as a pointer whose publisher has not run yet.
check >/dev/null
has "session pointer(s) absent" "an unresolvable managed pointer must be
reported rather than passed over"
has "WAYLAND_DISPLAY" "the absent pointers must be NAMED, since the useful
question is always WHICH one is missing"
no_has "[OK]   session pointers" "it reported the pointers healthy while one
of them does not exist at all, which is the fully-installed-and-fully-broken
state this marker contract exists to catch"

# --- and the readiness declaration is validated here, cheaply --------------
# A name in `env-ready` that nothing manages is a typo whose only symptom is a
# latch waiting for ever after the next reboot. Catching it in `mux check`
# means it is found while someone is looking, rather than during the one event
# it would ruin.
printf 'context-command cc\nenv-ready WAYLAND_DISPLAY\n' >"$T/conf/config"
check >/dev/null
has "[OK]   env-ready declared" "a declaration naming a MANAGED pointer is
well formed, whether or not that pointer happens to be live right now"

printf 'context-command cc\nenv-ready NOSUCHPOINTER\n' >"$T/conf/config"
check >/dev/null
# THE EXIT CODE IS DELIBERATELY NOT ASSERTED HERE. By this point in the
# fixture an earlier case has taken `tmux` off the curated PATH, so the check
# already exits non-zero for a reason that has nothing to do with this, and
# `[ "$RC" != 0 ]` would pass whether the new marker fires or not. A vacuous
# assertion reads as coverage, so the claim is the MARKER, and that it is a
# `[FAIL]` rather than a warn is what carries the exit code (asserted as a
# property of the marker contract elsewhere in this file).
has "[FAIL] env-ready names nothing manages" "the typo was not reported as a
FAIL, so the check would pass on a box where mux resume refuses"
has "NOSUCHPOINTER" "the refusal did not name the offending declaration"
printf 'context-command cc\n' >"$T/conf/config"

pass
