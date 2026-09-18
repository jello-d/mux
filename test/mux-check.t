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
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/share" "$T/conf/partitions" "$T/src"
cp -R "$HERE/share/." "$T/share/"
# The tmux stub answers list-keys and show-options from FILES, so one case can
# present a BROKEN server without any other case inheriting it. With the files
# absent it prints nothing and exits 0, which is what every case before the
# tmux-state section expects (and what "no server attached" looks like).
KEYS=$T/keys; SROPT=$T/sropt; SLOPT=$T/slopt
export KEYS SROPT SLOPT
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-keys*)                       [ -f "$KEYS" ]  && cat "$KEYS" ;;
*"show-options -gv status-right"*) [ -f "$SROPT" ] && cat "$SROPT" ;;
*"show-options -gv status-left"*)  [ -f "$SLOPT" ] && cat "$SLOPT" ;;
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
cat >"$KEYS" <<'EOF'
bind-key    -T prefix (       run-shell "mux cycle prev '#{client_name}'"
bind-key    -T prefix )       run-shell "mux cycle next '#{client_name}'"
bind-key    -T prefix b       run-shell "mux next-blocked '#{client_name}'"
bind-key    -T prefix r       run-shell "mux refresh"
bind-key    -T prefix R       run-shell "mux refresh --force"
EOF
printf '#(mux agent-render #S #{client_name})\n' >"$SROPT"
printf '#(mux style #S #{pane_pid})#[bold]#S\n' >"$SLOPT"
check >/dev/null
has "key bindings live" "a correctly bound server was not recognised"
has "status-right draws the agent strip" "a correct status-right was not seen"
has "status-left draws the session chip" "a correct status-left was not seen"
no_has "not bound to mux" "a healthy server reported broken bindings"

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
