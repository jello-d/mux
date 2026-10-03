#!/bin/sh
# test/mux-resume.t - `mux resume` end to end: reboot the machine, get your
# sessions back. Drives the real front end with a stubbed tmux, so the
# recording, the resolution and the rebuild are all exercised.
#
# The stub models a server whose live set lives in a file, so "reboot" is just
# truncating it while the cache survives, which is exactly the situation the
# feature exists for, and the one a snapshot-based design would break.
set -eu
_name=mux-resume
. "$(dirname "$0")/harness_lib"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
  exit 0; }

mkdir -p "$T/bin" "$T/conf" "$T/tree/alpha" "$T/tree/bravo" "$T/elsewhere"
for _d in alpha bravo; do git init -q "$T/tree/$_d"; done

cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
# LIVE holds "name<TAB>root" per running session.
case "$*" in
*has-session*)
  _n=$*; _n=${_n##*=}
  cut -f1 "$LIVE" 2>/dev/null | grep -qxF "$_n" && exit 0
  exit 1 ;;
*list-sessions*)
  [ -s "$LIVE" ] || exit 1
  case "$*" in
  *session_path*) sed 's/\t/ /' "$LIVE" ;;
  *) cut -f1 "$LIVE" ;;
  esac ;;
*new-session*)
  # -s NAME ... -c ROOT
  _n=; _c=
  while [ $# -gt 0 ]; do
    case $1 in -s) _n=$2; shift ;; -c) _c=$2; shift ;; esac; shift
  done
  printf '%s\t%s\n' "$_n" "$_c" >>"$LIVE" ;;
*kill-session*)
  _n=$*; _n=${_n##*=}
  grep -v "^$_n	" "$LIVE" 2>/dev/null >"$LIVE.t"; mv -f "$LIVE.t" "$LIVE" ;;
*kill-server*) : >"$LIVE" ;;
*switch-client*)
  # RECORDED SO FOCUS IS OBSERVABLE AT ALL, and `switch-client` ALONE is the
  # observable rather than "anything that switches". resume ends by attaching
  # to the set, which the stub sees as `attach-session`, and the FOCUS step
  # tries `switch-client` first: logging both made the two indistinguishable,
  # so a resume that focused nothing still showed the focus target, because
  # the fixture's only session is also what the final attach picks. ONE ARM
  # PER QUESTION, which is a rule this suite has paid for before.
  # `_t=$*` first, then strip: `${*##pat}` applies the pattern to EACH
  # parameter in bash, which is macOS's /bin/sh.
  _t=$*; _t=${_t##*=}
  printf '%s\n' "$_t" >>"${FOCUSLOG:-/dev/null}" ;;
*attach-session*)
  # THE LANDING, and its own arm rather than sharing FOCUSLOG with
  # switch-client above: resume both focuses (switch-client) and lands
  # (attach-session), and the comment above records what conflating them
  # already cost. ONE ARM PER QUESTION.
  _t=$*; _t=${_t##*=}
  printf '%s\n' "$_t" >>"${ATTACHLOG:-/dev/null}" ;;
*client_session*)
  # What `mux landing --record` asks the server. Its own pattern rather than a
  # bare *display-message*, which would also swallow the two format queries
  # below and answer them with a session name.
  printf '%s\n' "${WANTSESS:-}" ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
LIVE=$T/live; : >"$LIVE"; export LIVE
FOCUSLOG=$T/focus; : >"$FOCUSLOG"; export FOCUSLOG
ATTACHLOG=$T/attach; : >"$ATTACHLOG"; export ATTACHLOG
PATH=$T/bin:$PATH; export PATH

mux() {
  _d=$1; shift
  ( cd "$_d" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" GIT_CEILING_DIRECTORIES="$T" \
    "$HERE/bin/mux" "$@" ) 2>&1
}
live() { cut -f1 "$LIVE" | sort | tr '\n' ' '; }

# --- opening sessions records them, with their roots ------------------------
mux "$T/tree/alpha" go >/dev/null || fail "go alpha failed"
mux "$T/tree/bravo" go >/dev/null || fail "go bravo failed"
_set=$(mux "$T/elsewhere" resume --list | tr '\n' ' ')
[ "$_set" = "alpha bravo " ] || fail "recorded set is [$_set]"

# --- reboot: the server is gone, the cache is not ---------------------------
: >"$LIVE"
[ "$(live)" = " " ] || [ -z "$(live)" ] || fail "the fake reboot left sessions"

# Restore from a directory that is NEITHER session's root, to prove it uses the
# recorded roots and not the cwd.
_o=$(mux "$T/elsewhere" resume) || fail "resume failed: $_o"
case $_o in *"resumed 2"*) ;; *) fail "expected 2 resumed: [$_o]" ;; esac
[ "$(live)" = "alpha bravo " ] || fail "after resume, live is [$(live)]"
# ... and each landed back at its own root, not at $T/elsewhere.
grep -q "^alpha	$T/tree/alpha$" "$LIVE" \
  || fail "alpha resumed to the wrong root"
grep -q "^bravo	$T/tree/bravo$" "$LIVE" \
  || fail "bravo resumed to the wrong root"

# --- idempotent -------------------------------------------------------------
_o=$(mux "$T/elsewhere" resume) || fail "second resume failed"
case $_o in *"2 already up"*) ;; *) fail "expected both already up: [$_o]" ;;
esac

# --- killing forgets, so a resume does not resurrect it --------------------
mux "$T/elsewhere" kill alpha >/dev/null || fail "kill failed"
_set=$(mux "$T/elsewhere" resume --list | tr '\n' ' ')
[ "$_set" = "bravo " ] || fail "kill did not prune the set: [$_set]"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null || fail "resume after kill failed"
[ "$(live)" = "bravo " ] || fail "a killed session was resurrected: [$(live)]"

# --- resume addresses each session by its ROOT, the public form ------------
# Not by a private path through the resolver: `mux go <dir>` is a command
# anyone can type, so resume is a loop over it. Proven by a session whose root
# is a repo SUBDIRECTORY: addressing it by name alone could not distinguish
# it from its enclosing repo.
mkdir -p "$T/tree/bravo/inner"
printf 'inner       root=%s/tree/bravo/inner\n' "$T" >"$T/conf/profiles"
mux "$T/tree/bravo/inner" go inner >/dev/null || fail "opening inner failed"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null || fail "resume with a subdir failed"
grep -q "^inner	$T/tree/bravo/inner$" "$LIVE" \
  || fail "the subdirectory session did not come back at its own root"
rm -f "$T/conf/profiles"

# --- one broken entry must not cost the others ------------------------------
mux "$T/tree/alpha" go >/dev/null || fail "re-open alpha failed"
rm -rf "$T/tree/alpha"
: >"$LIVE"
_o=$(mux "$T/elsewhere" resume) || fail "resume with a dead root failed"
case $_o in *"could NOT build"*) ;; *) fail "no report of the dead root" ;; esac
[ "$(live)" = "bravo " ] || fail "the good session was lost: [$(live)]"

# --- ... and a dead entry can be FORGOTTEN ----------------------------------
# The set is pruned ONLY by `kill`, which used to require the session to be
# LIVE. But an entry whose root has gone is already dead: it could not be
# killed, so it could never be forgotten, and `resume` reported it as
# unbuildable on every run with no way out short of editing $MUX_CACHE by hand.
# Killing something already dead is still exactly what you mean.
mux_recorded() { mux "$T/elsewhere" resume --list | grep -qxF "$1"; }
mux_recorded alpha || fail "precondition: alpha should still be recorded"
_o=$(mux "$T/elsewhere" kill alpha) || fail "kill of a dead record failed: $_o"
case $_o in *forgotten*) ;; *) fail "kill of a dead record was silent: [$_o]" ;;
esac
mux_recorded alpha && fail "the dead entry survived kill"
# ... so resume stops reporting it.
: >"$LIVE"
_o=$(mux "$T/elsewhere" resume) || fail "resume after forgetting failed"
case $_o in
*"could NOT build"*) fail "resume still reports the forgotten entry: [$_o]" ;;
esac

# Neither live nor recorded is still an ERROR. Forgetting is for something mux
# actually remembers; a blanket success would make a typo look like a kill.
_o=$(mux "$T/elsewhere" kill nosuchsession) \
  && fail "kill of an unknown name should exit non-zero"
case $_o in *"no such session"*) ;; *) fail "unhelpful refusal: [$_o]" ;; esac

# --- a recorded name containing a SPACE is rebuilt whole --------------------
# `for n in $set` word-split the recorded names, so a session called
# `my project` was rebuilt as two phantoms (`my` and `project`), and the
# real one never came back. The set is newline separated for exactly this
# reason: a session name may contain a space, never a newline.
rm -f "$T"/state/sessions.*
: >"$LIVE"
mkdir -p "$T/tree/my project"
git init -q "$T/tree/my project" 2>/dev/null || true
# A BARE `go` from inside the directory: the directory is evidence, so the
# name is derived from its basename. A typed name nothing knows is refused by
# design, which is a different behaviour and not the one under test.
mux "$T/tree/my project" go >/dev/null 2>&1 \
  || fail "opening a spaced-name session failed"
_set=$(mux "$T/elsewhere" resume --list)
printf '%s\n' "$_set" | grep -qxF 'my project' \
  || fail "the spaced name was not recorded whole: [$_set]"
printf '%s\n' "$_set" | grep -qxF 'my' \
  && fail "the set holds a phantom 'my': [$_set]"
: >"$LIVE"
mux "$T/elsewhere" resume >/dev/null 2>&1 || true
grep -q "^my project	" "$LIVE" \
  || fail "the spaced session was not rebuilt: [$(cat "$LIVE")]"
grep -q "^my	" "$LIVE" && fail "a phantom session 'my' was built"

# --- nothing recorded is a loud, non-zero answer ----------------------------
rm -f "$T"/state/sessions.*
_o=$(mux "$T/elsewhere" resume) \
  && fail "resume with no set should exit non-zero"
case $_o in *"no sessions recorded"*) ;; *) fail "unhelpful message: [$_o]" ;;
esac

# --- a rebuild is a MUTATION, so it is logged -----------------------------
# At the worst possible moment to be unobservable. `mux resume` runs after a
# reboot, when "did my sessions come back?" is the only question anyone has, and
# the terminal that answered it has usually scrolled away or been closed by the
# time the question is asked. A set surviving intact while sessions are simply
# absent is indistinguishable, afterwards, from resume never having been run,
# which is exactly the ambiguity this removes.
MUX_LOG=$T/resume.log; export MUX_LOG
rm -f "$T"/state/sessions.*
: >"$LIVE"
mkdir -p "$T/tree/logged"
mux "$T/tree/logged" go >/dev/null || fail "go logged failed"
: >"$LIVE"                       # the reboot
: >"$MUX_LOG"
_o=$(mux "$T/elsewhere" resume 2>&1 || true)
_lg=$(cat "$MUX_LOG" 2>/dev/null || true)
case $_lg in
*' resume['*) ;;
*) fail "a rebuild wrote nothing to the log:
  said: $_o
  log:  $_lg" ;;
esac

# NAMES, NOT JUST COUNTS. "rebuilt 5" cannot say WHICH five, and the useful
# post-mortem is always about the one that is missing.
case $_lg in
*logged*) ;;
*) fail "the rebuild was logged without naming the sessions: $_lg" ;;
esac

# --- and what it could NOT do ---------------------------------------------
# The other half of the log's rule. A session whose ROOT has moved fails here
# and nowhere else, and a rebuild that quietly came back short is precisely what
# cannot be reconstructed later.
rm -f "$T"/state/sessions.*
: >"$LIVE"
mkdir -p "$T/tree/ghost"
mux "$T/tree/ghost" go >/dev/null || fail "go ghost failed"
: >"$LIVE"
rm -rf "$T/tree/ghost"           # the root goes away under it
: >"$MUX_LOG"
_o=$(mux "$T/elsewhere" resume 2>&1 || true)
_lg=$(cat "$MUX_LOG" 2>/dev/null || true)
case $_lg in
*"could NOT build"*ghost*) ;;
*) fail "a session that failed to rebuild was not logged BY NAME:
  said: $_o
  log:  $_lg" ;;
esac

# --- nothing recorded is a failure to do what was asked, and says so ------
# A reboot that lost the set looks exactly like this from the outside, and the
# difference between "the set was empty" and "resume was never run" is the
# whole question a post-mortem is trying to settle.
rm -f "$T"/state/sessions.*
: >"$MUX_LOG"
_o=$(mux "$T/elsewhere" resume 2>&1 || true)
_lg=$(cat "$MUX_LOG" 2>/dev/null || true)
case $_lg in
*"nothing recorded"*) ;;
*) fail "an empty set logged nothing:
  said: $_o
  log:  $_lg" ;;
esac
unset MUX_LOG

# --- the optional PARTITION and SESSION (0.56) ----------------------------
# `mux resume` grew two optional positional arguments. The first is ALWAYS
# the partition (never "whichever of these names one"), because that magic
# changes meaning the day you add a partition, and a session sharing a name
# with one would silently resume the wrong set. mux latch has already shipped
# a default that succeeded at the wrong thing and said nothing.

# An unknown partition is exit 3, mux's cross-cutting "the name is not known
# here". NOT an empty resume reporting "no sessions recorded": that reads as
# data loss when the truth is a typo.
#
# THE TRAILING `::` IS WHAT MAKES IT A PARTITION. A bare word is a SESSION in
# mux's one address grammar, so `resume nosuchpartition` now asks to focus a
# session of that name, and this case is about the PARTITION arm.
_rc=0
mux "$T/elsewhere" resume nosuchpartition:: >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 3 ] || fail "an unknown partition should exit 3, got $_rc"
grep -q "no such partition" "$T/out" \
  || fail "it did not say which: $(cat "$T/out")"
grep -q "known:" "$T/out" || fail "it did not list the known partitions"

# A SESSION that is not in the set is also exit 3, and refused BEFORE the
# rebuild: doing the work and then failing the one thing asked for would be
# reported as success with a footnote.
#
# SEEDED FIRST. The cases above end with an EMPTY set, and the empty-set
# refusal (exit 1) fires before the focus check is ever reached, so without
# a seed this passes or fails for a reason that has nothing to do with the
# focus target, while reading exactly like the case it claims to be.
mkdir -p "$T/tree/focus"
mux "$T/tree/focus" go >/dev/null || fail "seed: go focus failed"
: >"$LIVE"                       # the reboot, so a rebuild is observable
# The partition is DISCOVERED, not hardcoded: a literal would name a
# partition this fixture never records into, and the empty-set refusal would
# then fire again for the wrong reason.
_part=$(mux "$T/elsewhere" why 2>/dev/null \
  | awk '$1 == "partition" { print $2; exit }')
[ -n "$_part" ] || fail "could not learn the fixture's partition"
mux "$T/elsewhere" resume --list | grep -qxF focus \
  || fail "precondition: the seeded session was not recorded"
_rc=0
mux "$T/elsewhere" resume "$_part" nosuchsession >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 3 ] \
  || fail "an unknown focus session should exit 3, got $_rc:
$(cat "$T/out")"
grep -q "no such session recorded here" "$T/out" \
  || fail "it did not name the problem: $(cat "$T/out")"
# ... and it refused BEFORE rebuilding, which is the half that matters: the
# set is non-empty here, so a check made afterwards would have built `focus`
# and only then complained about the name it was given.
[ ! -s "$LIVE" ] || fail "it rebuilt before checking the focus target:
[$(cat "$LIVE")]"

# The NAMED partition with a session that IS in the set succeeds, so the
# check above is not simply refusing everything.
_rc=0
mux "$T/elsewhere" resume "$_part" focus >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a valid partition and session failed ($_rc):
$(cat "$T/out")"
grep -q "^focus	" "$LIVE" || fail "the named form did not rebuild:
[$(cat "$LIVE")]"

# --- THE ADDRESS GRAMMAR, which is now the documented form ----------------
# `[PARTITION::]SESSION`, the same grammar update-env and latch take, with the
# two-positional form above kept as the compatibility path because it is what
# an OLDER `mux latch` composes as a remote command.
#
# A BARE WORD IS A SESSION, and this is the BREAKING half: resume's first
# positional used to be a PARTITION, so `mux resume work` changed meaning.
# That is safe to take only because the failure is LOUD, which the
# nosuchpartition case above pins: a bare name that is not a recorded session
# exits 3 and lists the ones that are.
: >"$LIVE"
_rc=0
mux "$T/elsewhere" resume focus >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a BARE second word must be a SESSION, which is the
common case the grammar optimises for ($_rc): $(cat "$T/out")"
grep -q "^focus	" "$LIVE" || fail "the bare-session form did not rebuild:
[$(cat "$LIVE")]"

# ... and the qualified form means the same thing with the partition said.
#
# THE SET IS LEFT UP ON PURPOSE, which is the whole design of this case. The
# FOCUS is what it has to assert (the rebuild happens whether or not the
# session half of the address survived parsing, so asserting that proves only
# the PARTITION arrived), and with the set WIPED the rebuild attaches each
# session it creates, so the focus target and the rebuild's own last attach
# are the same string: the observable could not tell them apart. Resuming a
# set that is already up rebuilds nothing, so the only switch recorded is the
# focus. A fixture whose value coincides with the obvious constant is a test
# that proves nothing, which this one did until the corpus said so.
: >"$FOCUSLOG"
_rc=0
mux "$T/elsewhere" resume "$_part::focus" >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "the one-argument ADDRESS form failed ($_rc):
$(cat "$T/out")"
grep -q "already up" "$T/out" || fail "precondition: the set was not already
up, so the rebuild's own attach is indistinguishable from the focus:
$(cat "$T/out")"
grep -qxF focus "$FOCUSLOG" || fail "the address named session 'focus' and
nothing was switched to it: the set was left alone and the client left where
it was, which is the shape of bug \`mux latch box\` already shipped once.
[$(cat "$FOCUSLOG")]"

# A WINDOW IS REFUSED rather than ignored: resume rebuilds a session SET and
# lands on one of them, so a field it would silently drop is a flag that
# parses and does nothing, which this package has shipped once already.
: >"$LIVE"
_rc=0
mux "$T/elsewhere" resume "$_part::focus:2" >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a window field must be refused with 2, got $_rc:
$(cat "$T/out")"
grep -q "mux resume $_part::focus" "$T/out" \
  || fail "the refusal must PRESCRIBE the form without the window, or it
names a gap without saying how to close it: $(cat "$T/out")"
[ ! -s "$LIVE" ] || fail "it rebuilt despite refusing the address:
[$(cat "$LIVE")]"

# AND THE TWO-FIELD FORM IS NOT READ AS AN ADDRESS, which is why the
# discriminator is the ARGUMENT COUNT and not emptiness: `resume PART ''` is a
# deliberate two-field call naming a partition and no focus, and parsing it as
# an address would turn it into the session `PART`, silently.
: >"$LIVE"
_rc=0
mux "$T/elsewhere" resume "$_part" '' >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "a partition with an EMPTY focus must still resume the
set ($_rc): $(cat "$T/out")"
grep -q "^focus	" "$LIVE" || fail "the empty-focus pair did not rebuild:
[$(cat "$LIVE")]"

# A FAILED context-command refuses rather than resuming the baseline.
# `baseline` and `declined` are real answers meaning global; `failed` is the
# ABSENCE of an answer, and acting on it hands you somebody else's sessions
# while looking like success.
printf '#!/bin/sh\nexit 1\n' >"$T/conf/ctxfail"
chmod +x "$T/conf/ctxfail"
printf 'context-command ctxfail\n' >"$T/conf/config"
_rc=0
mux "$T/elsewhere" resume >"$T/out" 2>&1 || _rc=$?
rm -f "$T/conf/config"
[ "$_rc" = 1 ] || fail "a FAILED context-command should refuse, got $_rc"
grep -q "context-command FAILED" "$T/out" \
  || fail "the refusal did not say why: $(cat "$T/out")"

# --- WHERE YOU WERE: resume lands on the last active session ---------------
# The set is insertion-ordered and resume used to land on the first entry that
# came back, i.e. the OLDEST. Reported live: a box rebooted, latch reattached,
# and the human came back on a session untouched for days, so what they typed
# next went to the wrong agent.
#
# THE FIXTURE'S TWO ANSWERS MUST DIFFER, which is the whole reason it is built
# fresh here: `bravo` is the oldest and `delta` is the marked one, so the
# landing can tell them apart. A fixture whose value coincides with the
# obvious constant is a test that proves nothing, which the case above this
# one learned from the corpus.
rm -f "$T"/state/sessions.* "$T"/state/landing.*
: >"$LIVE"
mkdir -p "$T/tree/delta"; git init -q "$T/tree/delta"
mux "$T/tree/bravo" go >/dev/null || fail "landing seed: go bravo failed"
mux "$T/tree/delta" go >/dev/null || fail "landing seed: go delta failed"
_set=$(mux "$T/elsewhere" resume --list | tr '\n' ' ')
[ "$_set" = "bravo delta " ] \
  || fail "precondition: the set is not oldest-first: [$_set]"

# THE MARK IS WRITTEN THROUGH THE SHIPPED WRITER, never by hand. A fixture
# that spells the file itself encodes the format independently of the code and
# can then drift without ever going red, which is the rule this suite already
# states about the agent record. So this drives the real `mux landing` as
# the client-session-changed hook does, with $TMUX naming the partition's
# socket, which is also what proves the key is derived from the server rather
# than re-resolved from a context command.
_fkey=$(mux "$T/elsewhere" why 2>/dev/null \
  | awk '$1 == "partition" { print $2; exit }')
[ -n "$_fkey" ] || fail "could not learn the fixture's partition"
mkdir -p "$T/fakesock"
marklanding() {           # <session name to be current>
  ( cd "$T/elsewhere" && env -u MUX_SHARE MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" GIT_CEILING_DIRECTORIES="$T" \
    TMUX="$T/fakesock/$_fkey,1,0" WANTSESS="$1" \
    "$HERE/bin/mux" landing --record ) 2>&1
}

# A RECORDER THAT PRINTS ANYTHING FREEZES THE PANE: tmux run-shell shows a
# command's output in a view-mode buffer over the active pane, even with -b,
# until a key is pressed. So silence is a contract, not a style, and it is
# asserted on BOTH streams because a diagnostic on stderr would reach the
# same place.
_o=$(marklanding delta 2>&1)
[ -z "$_o" ] || fail "\`mux landing --record\` must print NOTHING, or every
session switch pops a view-mode buffer over the pane: [$_o]"
[ "$(mux "$T/elsewhere" landing)" = delta ] \
  || fail "the mark did not read back as delta:
[$(mux "$T/elsewhere" landing)]"
[ -f "$T/state/landing.$_fkey" ] \
  || fail "the mark was not filed under the partition the socket names:
state holds [$(ls "$T/state" | tr '\n' ' ')]"

: >"$LIVE"; : >"$ATTACHLOG"
mux "$T/elsewhere" resume >"$T/out" 2>&1 || fail "resume failed:
$(cat "$T/out")"
grep -qxF delta "$ATTACHLOG" || fail "resume landed somewhere other than the
session last active: the mark said delta and the landing was
[$(cat "$ATTACHLOG")]. Insertion order is CREATION order, so bravo here is
the oldest and exactly the wrong answer."

# THE CONTROL, which is what makes the case above mean anything: with NO mark
# the oldest is still correct, so the assertion is reading the mark rather
# than a fixture that can only ever say delta.
rm -f "$T/state/landing.$_fkey"
: >"$LIVE"; : >"$ATTACHLOG"
mux "$T/elsewhere" resume >"$T/out" 2>&1 || fail "resume with no mark failed:
$(cat "$T/out")"
grep -qxF bravo "$ATTACHLOG" || fail "with no mark recorded, the landing must
fall back to the oldest recorded session, which is what every install does
before this feature exists: [$(cat "$ATTACHLOG")]"

# AND A MARK NAMING A SESSION THAT DID NOT COME BACK falls back too. Checked
# for LIFE rather than membership, and after the rebuild, so a root that moved
# and a session killed from raw tmux are both covered by the one test.
marklanding ghost >/dev/null
[ "$(mux "$T/elsewhere" landing)" = ghost ] || fail "seed: the ghost mark"
: >"$LIVE"; : >"$ATTACHLOG"
mux "$T/elsewhere" resume >"$T/out" 2>&1 || fail "resume with a dead mark
failed: $(cat "$T/out")"
grep -qxF bravo "$ATTACHLOG" || fail "the mark named a session that never came
back, so the landing must fall through to the oldest live one rather than
attaching to a name that does not exist: [$(cat "$ATTACHLOG")]"

pass
