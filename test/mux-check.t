#!/bin/sh
# test/mux-check.t - `mux check`, the install audit.
#
# It is the thing you run to find out whether mux is coherently installed, so
# it being wrong is worse than most bugs: it does not merely fail, it tells you
# everything is fine. Its contract is small and exact --
#
#   one [OK]/[WARN]/[FAIL] line per check, and a NON-ZERO exit on any [FAIL]
#
# -- and the second half is the part with teeth, because anything gating on
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
# Everything mux-check shells out to. A reduced PATH is the point -- the
# notification checks below turn backends on and off by their PRESENCE -- so
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
  OUT=$(env -u MUX_NOTIFY_SEND -u MUX_NOTIFY_CLOSE \
    PATH="$T/bin" NO_COLOR=1 MUX_DIR="$T/conf" \
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
# the frontmatter installs cleanly, errors nothing and then never triggers --
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

# --- no scan roots at all: discovery is OFF, and says so ------------------
rm -f "$T/conf/partitions/probe.partition"
check >/dev/null
has "no scan roots" "silent about discovery being off"
has "discovery is off" "did not say what that means"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# --- notifications are reported in TWO halves ----------------------------
# Raising and clearing can be separately absent, and a box that raises but
# cannot clear accumulates dead banners -- the failure the old mako-only
# close produced everywhere that was not mako.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/notify-send"
chmod +x "$T/bin/notify-send"
check >/dev/null
has "notifications raise but never clear" "no report of a missing closer"
[ "$RC" -eq 0 ] || fail "an absent notification path must not FAIL"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/gdbus"; chmod +x "$T/bin/gdbus"
check >/dev/null
has "cleared via gdbus" "a usable closer was not credited"
rm -f "$T/bin/notify-send"
check >/dev/null
has "no notify-send" "silent about being unable to notify at all"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/notify-send"
chmod +x "$T/bin/notify-send"

# Both overrides set is a supported path; half an override is a mistake.
check MUX_NOTIFY_SEND=/bin/true MUX_NOTIFY_CLOSE=/bin/true >/dev/null
has "notifications overridden" "the override pair was not recognised"
check MUX_NOTIFY_SEND=/bin/true >/dev/null
has "together, or neither" "half an override was not called out"

# --- the product WORKING, not merely installed ----------------------------
# Everything above is a presence check: files exist, commands resolve, config
# parses. Asked the only question that matters -- what would this say about a
# box that is fully installed and fully BROKEN? -- the answer used to be [OK]
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
# failure set it. Caught by mutation -- downgrading the binding [FAIL] to a
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
# a server missing both -- asserting a green check against a stale idea of
# what green means.
# ANY bind whose command mentions mux, matching what the check now derives.
# The narrower `run-shell` pattern missed `prefix ?` (a `display-popup`) the day
# it was added, on BOTH sides -- so the check stopped expecting it and this
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
reads as drift its apply can repair -- and it cannot"

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
# advice that CANNOT COME TRUE -- the line is already there -- and a provisioner
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
# Measured live on 2026-09-27 -- `prefix u` and the whole
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
# fail -- but it is said OUT LOUD, because a check that silently skips its only
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
OUT=$(env -u MUX_NOTIFY_SEND -u MUX_NOTIFY_CLOSE \
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

# --- tmux itself: the one hard runtime dependency -------------------------
rm -f "$T/bin/tmux"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing tmux exited 0"
has "tmux not found" "no report of the missing dependency"

pass
