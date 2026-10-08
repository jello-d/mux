#!/bin/sh
# test/mux-strip.t - mux-agent-state-render, the status-right session strip.
#
# The largest file in the tree and, until now, the only substantial one with no
# test at all. Its interesting behaviour is GRACEFUL REDUCTION: the strip is
# measured against status-right-length and, when the full chips overflow, it
# degrades in tiers rather than letting tmux truncate it blind:
#
#   full chips -> drop the age -> fold agentless runs -> window around the
#   current session with edge counts -> a bare "needs-you count · total"
#
# with ONE invariant across all of them: a session that needs you is never
# silently dropped. It stays a chip, becomes a caution-marked edge count, or
# survives in the summary count. Blind truncation would drop whatever fell off
# the right, which could be exactly that session, which is why the tiers
# exist.
#
# The budgets here are not hardcoded widths. The test sweeps the whole range
# and asserts the LADDER (each tier is reachable, and reduction is monotonic)
# plus the invariant AT EVERY WIDTH, so it pins the contract rather than the
# current arithmetic and survives a chip gaining a character.
set -eu
_name=mux-strip
. "$(dirname "$0")/harness_lib"
. "$HERE/lib/mux-agent-state_lib"      # the glyph constants

mkdir -p "$T/bin" "$T/run/mux/agent-state/global"
SESSIONS=$T/sessions
PANES=$T/panes
export SESSIONS PANES
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*) cat "$SESSIONS" ;;
*list-panes*)    cat "$PANES" ;;
*show-options*)  printf '\n' ;;
# The strip draws the view indicator at its right edge, so the probe behind
# it has to answer deterministically or the tail would vary run to run.
# One client, window matching it: calm, mode auto.
*list-clients*)  printf '/dev/pts/0 161x64 alpha 1\n' ;;
*client_width*)  printf '161x64 161x63 latest on\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

printf 'alpha\nbravo\ncharlie\ndelta\n' >"$SESSIONS"
printf '%%1\n%%2\n%%3\n' >"$PANES"
# Record: state window pane epoch notif SESSION: the session LAST, so a
# name containing a space is read back whole. notif is `-` when absent,
# never empty: an empty field collapses in the whitespace run and shifts
# everything after it.
# epoch 1 keeps ages stable and large.
st() { printf '%s 0 %s 1 %s %s\n' "$2" "$1" "${4:--}" "$3" \
  >"$T/run/mux/agent-state/global/${1#%}"; }
st %1 blocked alpha
st %2 working delta
# bravo and charlie have no agent at all: the fold candidates.

# render CURRENT BUDGET -> the strip, tmux format escapes and all.
# A PRIVATE TMPDIR FOR EVERY RENDER, so the leak assertion below can be about
# the render and nothing else. It used to count entries in the SHARED $TMPDIR
# before and after, which is a claim about the whole machine: `test/run` is
# PARALLEL and every other test's `mktemp -d` creates a directory in there, so
# any file one of them made during the window tripped it. It passed on timing
# alone and went red on ubuntu the moment an unrelated commit made two other
# tests slower. A global-state assertion in a concurrent suite is measuring
# the scheduler.
mkdir -p "$T/tmpprobe"
render() {
  env -u TMUX -u TMUX_PANE XDG_RUNTIME_DIR="$T/run" TMPDIR="$T/tmpprobe" \
    MUX_STRIP_WIDTH="$2" PATH="$T/bin:$PATH" \
    "$HERE/libexec/mux-agent-state-render" "$1" testclient 2>/dev/null
}
# The VISIBLE text: tmux #[...] directives carry no display width.
vis() { printf '%s' "$1" | sed 's/#\[[^]]*\]//g'; }
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in [$(vis "$1")]" ;;
  esac; }
no_has() { case "$1" in *"$2"*) fail "$3: unwanted [$2] in [$(vis "$1")]" ;;
  esac; }

# --- UNWIRED: mux started an agent and has never heard from it ------------
# THE FIRST-RUN FAILURE, and the reason it needs a glyph of its own: install
# mux, start a session, and every chip reads `⚫`, which is also exactly what
# a plain shell looks like, so nothing says the hooks were never wired and the
# reasonable conclusion is that mux is broken.
#
# The signal is `@mux-agent` set on a pane with NO record for that session: a
# wired agent emits on SessionStart, so the absence of any record is the tell.
# Deliberately not a process check: tmux reports a live Claude pane's
# `#{pane_current_command}` as the SHELL, and `#{pane_start_command}` keeps
# naming the agent long after it exits, so neither can tell a running agent
# from a finished one (measured).
#
# Fields: pane id, @mux-agent, session: the session LAST because a name may
# contain a space.
printf '%%1\t\t\talpha\n%%2\t\t\tdelta\n%%3\t1\t\tcharlie\n' \
  >"$PANES"
_o=$(vis "$(render delta 400)")
has "$_o" "$MUX_GLYPH_UNWIRED charlie" "charlie has an agent pane and no
record, so it must draw the unwired glyph rather than reading like a plain
shell, which is the whole first-run problem"

# AND IT DOES NOT FIRE FOR EVERYONE, which is the half that makes the glyph
# mean something: bravo has no record AND no agent pane, so it is genuinely
# agentless and stays `none`. Asserted separately because one "the strip
# changed" check passes with the condition inverted.
has "$_o" "$MUX_GLYPH_NONE bravo" "bravo has no agent pane, so it is agentless
rather than unwired: marking every recordless session would make the glyph
noise"

# AND IT SURVIVES REDUCTION. The fold tier collapses runs of agentless
# sessions to a count, and an unwired session must not disappear into one: it
# is the one chip the user needs to see. It breaks the run rather than joining
# it, which follows from the fold testing for `none` exactly.
_o=$(vis "$(render delta 46)")
has "$_o" "$MUX_GLYPH_UNWIRED" "the unwired glyph was folded away under
reduction, which hides the only thing telling the user why the strip is empty"
printf '%%1\n%%2\n%%3\n' >"$PANES"

# INSERTED HERE, NOT EARLIER, because the cases above share one `_o`
# across several assertions: a new case that re-renders in the middle
# of them silently re-points every later check at its own output, which
# is the positional hazard this suite already records about a fixture
# defined twice.
# --- A WORKER IS INVISIBLE TO THE HUMAN'S STRIP ---------------------------
# vicus's R2: a human surface must not report an agent owed elsewhere. A
# worker blocked on its SUPERVISOR would otherwise paint its whole session
# blocked, so one checkpoint makes a project look stuck.
#
# TWO ASSERTIONS, because the pane is excluded from TWO things and either
# alone leaves the session visibly wrong. Its RECORD must not speak for the
# session, and `@mux-agent` on it must not count either: filtering only the
# records would leave a worker-only session drawing the UNWIRED plug forever,
# which is the loudest glyph on the strip announcing the one agent the human
# was told to ignore.
printf '%%1\t\t\talpha\n%%7\t1\tagent\tbravo\n' >"$PANES"
agent_rec "$T/run/mux/agent-state/global/p7" blocked %7 100 bravo x
_o=$(vis "$(render alpha 400)")
no_has "$_o" "$MUX_GLYPH_BLOCKED bravo" "a worker blocked on its supervisor
painted the human's chip for bravo. That is the inversion R2 exists to
prevent, on the surface it names first."
no_has "$_o" "$MUX_GLYPH_UNWIRED bravo" "filtering the record alone left the
session drawing the UNWIRED plug, which is louder than the chip it replaced:
the pane has to be invisible to BOTH questions."
has "$_o" "$MUX_GLYPH_NONE bravo" "a session whose only agent is a worker must
read as agentless, which is what it is from the human's side"

# AND THE CONTROL: the same record with no attention declared DOES paint the
# chip, so the silence above is the marker's doing and not a broken fixture.
printf '%%1\t\t\talpha\n%%7\t1\t\tbravo\n' >"$PANES"
_o=$(vis "$(render alpha 400)")
has "$_o" "$MUX_GLYPH_BLOCKED bravo" "control: an undeclared blocked agent
must still reach the human, or the assertions above prove only that the
fixture is broken"
rm -f "$T/run/mux/agent-state/global/p7"
printf '%%1\n%%2\n%%3\n' >"$PANES"


# --- the widest tier: every session, with its age -------------------------
_o=$(vis "$(render delta 400)")
for _s in alpha bravo charlie delta; do
  has "$_o" "$_s" "full strip: missing $_s"
done
has "$_o" "$MUX_GLYPH_BLOCKED" "full strip: no blocked glyph"
# fmt_age renders a fixed 3-col field; epoch 1 pins it at the 99h ceiling.
# NOT a bare "d": that matches the "d" in "delta" and proves nothing.
case $_o in *99h*) ;; *) fail "full strip: no age field in [$_o]" ;; esac

# --- the narrowest tier: a bare count -------------------------------------
_o=$(vis "$(render delta 6)")
no_has "$_o" alpha "summary: still naming sessions"
has "$_o" "4" "summary: lost the session total"
has "$_o" "$MUX_GLYPH_BLOCKED" "summary: dropped the needs-you count"

# --- ONE sweep: the invariant at every width, and every tier reachable ----
# Dense across the range where the tiers actually change, plus a few wide
# samples. Swept rather than spot-checked because the boundaries are
# arithmetic, and a sample would sail straight past a hole between two tiers.
#
# Tier discrimination is ORDERED and uses marks that cannot occur otherwise:
# `·2·` is the fold, `‹`/`›` the window edges, `99h` the age field.
# Testing for a bare "d" as the age marker matched the "d" in "delta", which is
# how this first passed while proving nothing.
_saw_age=0 _saw_noage=0 _saw_fold=0 _saw_edge=0 _saw_sum=0
_check() {
  _r=$(vis "$(render delta "$1")")
  [ -n "$_r" ] || fail "width $1: empty strip"
  case $_r in
    *"$MUX_GLYPH_BLOCKED"*|*alpha*) ;;
    *) fail "width $1: the blocked session vanished: [$_r]" ;;
  esac
  case $_r in
    *"·2·"*)   _saw_fold=1 ;;
    *"‹"*|*"›"*) _saw_edge=1 ;;
    *99h*)                 _saw_age=1 ;;
    *alpha*)               _saw_noage=1 ;;
    *)                     _saw_sum=1 ;;
  esac
}
_w=1
while [ "$_w" -le 100 ]; do _check "$_w"; _w=$((_w + 1)); done
for _w in 140 200 400; do _check "$_w"; done

[ "$_saw_age"   -eq 1 ] || fail "the full (aged) tier is never selected"
[ "$_saw_noage" -eq 1 ] || fail "the drop-the-age tier is never selected"
[ "$_saw_fold"  -eq 1 ] || fail "the fold-agentless tier is never selected"
[ "$_saw_edge"  -eq 1 ] || fail "the window tier is never selected"
[ "$_saw_sum"   -eq 1 ] || fail "the summary tier is never selected"

# --- reduction is MONOTONIC ------------------------------------------------
# A narrower budget must never produce a WIDER strip. Compared on visible
# length, which is what the budget is denominated in.
_prev=0
_w=1
while [ "$_w" -le 400 ]; do
  _len=$(printf '%s' "$(vis "$(render delta "$_w")")" | wc -m | tr -d ' ')
  [ "$_len" -ge "$_prev" ] || fail \
    "width $_w produced a shorter strip than a narrower budget"
  _prev=$_len
  _w=$((_w + 40))
done

# --- the view indicator is FIXED FURNITURE at the right edge --------------
# It is drawn by this script rather than as its own status-left segment so its
# width comes out of the SAME budget the tiers spend: a second #() appended
# by tmux would be invisible to them and would silently push the strip past
# status-right-length. Two things follow, and both are contract:
#
#   it is present at EVERY width, including the summary floor, so the bar never
#   changes width as tension comes and goes; and
#   reduction never eats it, because it is not a chip that may be dropped.
#
# (Below about ten columns the summary tier is already at its own floor and
# cannot compress further, so the total exceeds a budget that small. That is
# the pre-existing floor, not something the indicator introduced.)
_w=400
while [ "$_w" -ge 10 ]; do
  _r=$(vis "$(render delta "$_w")")
  case $_r in
    *"✱"*) ;;
    *) fail "width $_w: the view indicator was dropped: [$_r]" ;;
  esac
  _w=$((_w - 1))
done
# ... and it is the LAST thing on the strip, after a separator.
_edge=$(vis "$(render delta 400)")
case $_edge in
  *"│✱") ;;
  *) fail "the indicator is not at the right edge: [$_edge]" ;;
esac

# --- the current session is the one marked ---------------------------------
_o=$(render alpha 400)
case $_o in *"underscore"*) ;; *) fail "no current-session chip drawn" ;; esac

# --- `mux hide` drops a session from THIS client's strip only --------------
mkdir -p "$T/run/mux-exclude"
printf 'charlie\n' >"$T/run/mux-exclude/testclient"
_o=$(vis "$(render delta 400)")
no_has "$_o" charlie "hidden session still on the strip"
has "$_o" bravo "hiding one session dropped another"
# ... and another client is unaffected: the set is keyed per client.
_o2=$(vis "$(env -u TMUX XDG_RUNTIME_DIR="$T/run" MUX_STRIP_WIDTH=400 \
  PATH="$T/bin:$PATH" "$HERE/libexec/mux-agent-state-render" delta other)")
has "$_o2" charlie "hiding leaked to another client"
rm -f "$T/run/mux-exclude/testclient"

# --- a FAILED pane query must never read as "every pane died" --------------
# This script uses a bare `tmux`, so it inherits its server from $TMUX. Run
# from a shell without one (over ssh, from a cron, or by hand to see what the
# strip says), it asks tmux's DEFAULT socket, which usually has no server, so
# list-panes errors and returns nothing. Treating that as truth meant every
# recorded pane looked dead and the prune deleted EVERY agent's state on the
# real server. It did exactly that on a live machine, from one diagnostic run.
#
# Destroying state on a failed READ is the worst response available, so an
# empty pane list is refused rather than believed.
cat >"$T/bin/tmux.broken" <<'EOF'
#!/bin/sh
case "$*" in
*list-panes*) echo "error connecting to /tmp/tmux-1000/default" >&2; exit 1 ;;
*list-sessions*) cat "$SESSIONS" ;;
*show-options*)  printf '\n' ;;
*list-clients*)  printf '/dev/pts/0 161x64 alpha 1\n' ;;
*client_width*)  printf '161x64 161x63 latest on alpha\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux.broken"
st %1 blocked alpha
st %2 working delta
_kept=$(ls "$T/run/mux/agent-state/global" | tr '\n' ' ')
cp "$T/bin/tmux.broken" "$T/bin/tmux"
render delta 400 >/dev/null 2>&1 || true
_after=$(ls "$T/run/mux/agent-state/global" 2>/dev/null | tr '\n' ' ')
[ "$_after" = "$_kept" ] \
  || fail "a failed pane query pruned state: had [$_kept] left [$_after]"
# Put the working stub back for everything below.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*) cat "$SESSIONS" ;;
*list-panes*)    cat "$PANES" ;;
*show-options*)  printf '\n' ;;
*list-clients*)  printf '/dev/pts/0 161x64 alpha 1\n' ;;
*client_width*)  printf '161x64 161x63 latest on alpha\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

# --- a dead pane's state file is pruned ------------------------------------
# A killed agent never fires its Stop hook, so nothing else removes these; a
# phantom would keep reporting state for a pane that is gone.
st %9 blocked ghost
[ -f "$T/run/mux/agent-state/global/9" ] || fail "setup: no phantom to prune"
render delta 400 >/dev/null
[ -f "$T/run/mux/agent-state/global/9" ] \
  && fail "a state file for a dead pane survived the render"
# ... and a LIVE pane's file is untouched.
[ -f "$T/run/mux/agent-state/global/1" ] || fail "pruned a live pane's state"

# --- the render KEEPS NO SCRATCH, and that is a bug fix -------------------
# It has to measure the strip's WIDTH before drawing it, so the records exist
# before the output does. Two earlier shapes both failed:
#
#   mktemp         unique per render, so no render disturbed another, and an
#                  anonymous /tmp/tmp.XXXXXXXXXX is indistinguishable from
#                  every other program's scratch once leaked, so nothing could
#                  prune it. 674 were counted on one box.
#   a fixed name   prunable, and WRONG: this runs per client every
#                  status-interval AND again on every redraw a session switch
#                  forces, so two renders for one client overlap routinely and
#                  shared one pair of files.
#
# The records live in a VARIABLE now, which is private to the process by
# construction. Asserted as an ABSENCE, in both candidate locations, because
# the bug either shape would reintroduce is a FILE existing at all.
_rd=$T/run/mux/render
render delta 400 >/dev/null
[ ! -d "$_rd" ] || [ "$(ls -1 "$_rd" | wc -l)" -eq 0 ] \
  || fail "the render left scratch under the runtime dir: [$(ls "$_rd")].
It keeps its records in a variable; a file there is a shape that can be
shared between two concurrent renders of one client."
# EVERY render in this file has run by now and they all shared that TMPDIR,
# so emptiness is a stronger claim than the before/after count ever made.
[ "$(ls -1A "$T/tmpprobe" | wc -l)" -eq 0 ] \
  || fail "a render wrote into \$TMPDIR: [$(ls -1A "$T/tmpprobe")].
An anonymous scratch file is the one shape nothing can prune once it leaks."

# TWO RENDERS OF THE SAME STATE ARE IDENTICAL. Guards accumulation whatever
# holds the records: appending without resetting makes the strip CHANGE, and
# "changed" rather than "grew" is deliberate, since extra records can also
# make it SHRINK by pushing it into a narrower reduction tier.
_n1=$(render delta 400); _n2=$(render delta 400)
[ "$_n1" = "$_n2" ] || fail "the strip changed between two renders of the same
state (${#_n1} -> ${#_n2}), so the records are accumulating"

# --- CONCURRENT RENDERS OF ONE CLIENT: the regression ----------------------
# THE LIVE DEFECT, reported as the bar duplicating entries, then wiping out,
# and healing itself. With a shared fixed-name scratch, two overlapping
# renders interleaved their appends (a session drawn twice) and the first to
# finish REMOVED the files the second was still reading (short, or blank).
# Measured before the fix: 44 of 50 concurrent renders wrong, strips up to
# 2.5x too long. Self-healing, because the next render that did not overlap
# was right, which is what made it read as a drawing glitch rather than a bug.
#
# EVERY render must equal the single-run answer, not merely be non-empty: a
# count-based assertion passes on a strip that drew the wrong sessions.
_truth=$(render delta 400)
mkdir -p "$T/conc"
_i=0
while [ "$_i" -lt 6 ]; do
  _i=$((_i + 1))
  _j=0
  while [ "$_j" -lt 4 ]; do
    _j=$((_j + 1))
    render delta 400 >"$T/conc/$_i.$_j" &
  done
  wait
done
_bad=0 _tot=0
for _f in "$T/conc"/*; do
  _tot=$((_tot + 1))
  [ "$(cat "$_f")" = "$_truth" ] || _bad=$((_bad + 1))
done
[ "$_tot" -eq 24 ] || fail "precondition: $_tot of 24 concurrent renders ran,
so this proves less than it claims"
[ "$_bad" -eq 0 ] || fail "$_bad of $_tot CONCURRENT renders of one client
disagreed with the single-run strip. Two renders are sharing mutable state,
which is what made the bar duplicate entries and then blank itself."

# --- `humming` reaches the strip, and the sidecars survive the prune -------
# A GEAR, NOT THE CHECK, for a session whose turn ended with work it started
# still running. "done" is the misleading word and `✅` the misleading glyph.
st %3 idle charlie
_o=$(render charlie 400)
has "$_o" "$MUX_GLYPH_IDLE" "precondition: a plain idle session draws a check"
# The age text, read off the IDLE chip BEFORE the sidecar exists: the fixture
# pins epoch 1 so every age is the same large value, which makes this exact
# and needs no arithmetic.
_agepat="s/.*charlie *\\([0-9][0-9]*[a-z]\\).*/\\1/p"
_age=$(vis "$_o" | sed -n "$_agepat")
[ -n "$_age" ] || fail "precondition: no age on an idle chip to compare with"

sleep 30 & _sjob=$!
printf '%s\n' "$_sjob" >"$T/run/mux/agent-state/global/3.hum"
_o=$(render charlie 400)
has "$_o" "$MUX_GLYPH_HUMMING" "a session with live background work must draw
the gear: the colour says ready, the glyph says something is still running"

# AND IT CARRIES ITS AGE, like every other live state. How long a job has been
# running is the useful half ("still going after 5m" reads very differently
# from "just started"), and the age is drawn from a HARDCODED state list, so a
# new state silently loses it: measured, the first version rendered
# `⚙️ charlie` with an empty age column. Asserted by WIDTH against the same
# session drawn idle, because both carry the same name and the same age, so a
# dropped field is the only thing that can make them differ.
# PULLED OUT OF THE HUMMING CHIP ITSELF, not matched loosely across the strip.
# The first version globbed `*gear charlie*AGE*`, which any LATER chip's age
# satisfies: the fixture's other sessions carry the same age, so the mutation
# SURVIVED and the assertion read as coverage. Only spaces may sit between the
# name and its age, which is what makes the absence detectable.
_hpat="s/.*$MUX_GLYPH_HUMMING charlie *\\([0-9][0-9]*[a-z]\\).*/\\1/p"
_hage=$(vis "$_o" | sed -n "$_hpat")
[ "$_hage" = "$_age" ] || fail "the humming chip dropped its age (idle shows
[$_age], humming shows [$_hage]): the age is drawn from a HARDCODED list of
states and a new one silently loses it. Measured: the first version rendered
the gear with an empty age column."

# AND IT CARRIES A CHIP LOOK OF ITS OWN, which is the SECOND hardcoded
# per-state list behind this one chip and was missed when the first was fixed.
# `_style` maps a state to a style and an accent, and its `*)` arm is the dim
# `unknown` look: a bare fg and NO bg. So a new state does not render wrongly,
# it renders as the colour reserved for "mux cannot say", which is how this
# shipped. MEASURED LIVE on a real session: `#[fg=colour250]` with no
# background, indistinguishable from an agentless chip, while every other live
# state draws a filled one.
#
# READ OFF AN ORDINARY CHIP, NOT THE CURRENT ONE, which is the whole reason
# this needs its own render: `render CURRENT ...` makes charlie the CURRENT
# session, whose body is deliberately white on every theme so that "where am
# I" never rides on a hue, and whose state colour lives in the FRAME instead.
# Extracting a bg from that chip reads `fg=colour232` and proves nothing.
_sty() { printf '%s' "$1" | sed -n \
  "s/.*#\\[\\([^]]*\\)\\] $2 charlie.*/\\1/p"; }
_bg() { printf '%s' "$1" | sed -n 's/.*\(bg=[^],]*\).*/\1/p'; }
_hsty=$(_sty "$(render alpha 400)" "$MUX_GLYPH_HUMMING")
case ${_hsty:-} in
  *bg=*) ;;
  *) fail "the humming chip carries no background: [$_hsty]. It fell through
_style's \`*)\` arm to the dim UNKNOWN look, so a session that is ready with
work still running draws as one mux knows nothing about." ;;
esac

# AND THE CONTROL, which is what makes the gear the sidecar's doing rather
# than a fixture that cannot fail: the OTHER idle sessions still draw a check.
kill "$_sjob" 2>/dev/null; wait "$_sjob" 2>/dev/null || true
_o=$(render charlie 400)
has "$_o" "$MUX_GLYPH_IDLE" "with the job gone the strip must go back to the
check with nothing re-emitted, or the mark never clears"
no_has "$_o" "$MUX_GLYPH_HUMMING" "the gear outlived the work it stood for"

# AND IT IS NOT IDLE'S BACKGROUND, asserted separately from "it has one"
# because the two mutations are different bugs and one "they differ" check
# kills neither: a chip painted exactly like idle is a state whose only cue is
# the glyph, and a chip with no bg at all is the bug above. The brief was one
# hue at two depths, not one chip at two glyphs. Taken from the SAME session
# now that its job has gone, so nothing is added to the fixture: a case
# inserted mid-file re-points every later assertion, which this suite has
# already paid for.
_isty=$(_sty "$(render alpha 400)" "$MUX_GLYPH_IDLE")
[ -n "$(_bg "$_isty")" ] || fail "precondition: no idle bg to compare against
(idle style read as [$_isty])"
[ "$(_bg "$_hsty")" != "$(_bg "$_isty")" ] || fail "humming and idle draw the
same background [$(_bg "$_hsty")], so the only thing separating 'done' from
'still running' is the glyph."

# --- THE PRUNE WAS DELETING SIDECARS, which is a bug this change found -----
# The prune reads every file in the record directory, and a sidecar parses
# with an EMPTY pane: `*" $pane "*` then asks whether the live list contains
# two adjacent spaces, it does not, and the file was REMOVED. Measured: a
# directory holding `1`, `1.beat` and `1.hum` came back from one render
# holding `1`.
#
# THE CONSEQUENCE WAS NOT THEORETICAL. The strip renders every
# status-interval, so the 0.49 beat mark never survived two seconds and a
# second beat could never find the first. That is exactly why these notes
# record "zero beat corroborated lines in two days of logs, on two boxes"
# while the path corroborates first time when driven directly.
printf '%s\n' 1 >"$T/run/mux/agent-state/global/3.beat"
printf '%s\n' 999999 >"$T/run/mux/agent-state/global/3.hum"
render charlie 400 >/dev/null
[ -f "$T/run/mux/agent-state/global/3.beat" ] \
  || fail "a render DELETED the beat sidecar of a live pane. The strip draws
every status-interval, so the corroboration mark can never survive long
enough for a second beat to find it."
[ -f "$T/run/mux/agent-state/global/3.hum" ] \
  || fail "a render deleted the humming sidecar of a live pane"

# AND A DEAD PANE'S SIDECARS GO WITH ITS RECORD, or pruning leaves orphans
# that nothing will ever collect. %9 is in no live pane list.
st %9 idle charlie
printf '%s\n' 1 >"$T/run/mux/agent-state/global/9.beat"
printf '%s\n' 2 >"$T/run/mux/agent-state/global/9.hum"
render charlie 400 >/dev/null
[ ! -e "$T/run/mux/agent-state/global/9" ] \
  || fail "precondition: the dead pane's record was not pruned, so the
sidecar assertion below proves nothing"
[ ! -e "$T/run/mux/agent-state/global/9.hum" ] \
  || fail "the record was pruned and its sidecar was left behind"
[ ! -e "$T/run/mux/agent-state/global/9.beat" ] \
  || fail "the record was pruned and its beat sidecar was left behind"

pass
