#!/bin/sh
# test/mux-setup.t - `mux setup claude`, the one verb that writes somebody
# else's configuration file.
#
# THE FAILURE THAT MATTERS HERE IS NOT "mux did not get wired". It is "mux ate
# somebody's settings", so most of this file is about what must SURVIVE: other
# hooks on the same event, unrelated keys, and a file that does not parse. Every
# other part of mux refuses to write another program's config (`mux skill`
# prints, deliberately); this verb is the exception the first-run experience
# needs, and the assertions are the price of it.
#
# CLAUDE_CONFIG_DIR points everything at a scratch tree, so nothing here can
# reach the real one.
set -eu
_name=mux-setup
. "$(dirname "$0")/harness_lib"

command -v python3 >/dev/null 2>&1 || {
  printf 'skip %s (no python3)\n' "$_name"; exit 0; }

CDIR=$T/claude; mkdir -p "$CDIR"
SET=$CDIR/settings.json
mux() { env -u MUX_SHARE CLAUDE_CONFIG_DIR="$CDIR" "$HERE/bin/mux" "$@"; }
# jq is not a dependency of this project, so questions are asked of python.
j() { python3 -c "
import json,sys
d=json.load(open('$SET'))
sys.stdout.write(str($1))"; }

# --- refusals, before anything is written ---------------------------------
_rc=0; _o=$(mux setup 2>&1) || _rc=$?
[ "$_rc" = 2 ] || fail "no agent named should be a usage error, got $_rc"
_rc=0; _o=$(mux setup nosuchagent 2>&1) || _rc=$?
[ "$_rc" = 1 ] || fail "an unknown agent should exit 1, got $_rc"
case $_o in
  *"have: claude"*) ;;
  *) fail "the refusal did not name what mux ships, so a typo looks like a
missing feature: [$_o]" ;;
esac
# A NAME BECOMES A PATH, the same rule `mux skill` follows.
for _bad in ../../etc/passwd UPPER 'a b'; do
  _rc=0; mux setup "$_bad" >/dev/null 2>&1 || _rc=$?
  [ "$_rc" = 2 ] || fail "[$_bad] should be a usage error, got $_rc"
done
[ -e "$SET" ] && fail "a refusal created $SET"

# --- the EVENTS come from mux, not from a list typed here -----------------
# `mux agent-hook`'s table IS the contract. Scraped, so this cannot wire an
# event mux would reject (exit 2, logged) nor miss one it understands, and so
# that adding an event to the table wires it without anyone remembering to.
_hookf=$HERE/libexec/mux-agent-hook
# Shape, not column: an arm's indentation is not part of the contract.
_events=$(sed -n 's/^[[:space:]]*\([A-Za-z]*\))  *set -- .*/\1/p' "$_hookf")
[ -n "$_events" ] || fail "no events scraped; this file proves nothing"

# --- a dry run changes nothing -------------------------------------------
_o=$(mux setup claude --dry-run 2>&1) || fail "dry-run failed: $_o"
for _e in $_events; do
  case $_o in
    *"$_e"*) ;;
    *) fail "the plan does not mention $_e: [$_o]" ;;
  esac
done
[ -e "$SET" ] && fail "--dry-run wrote $SET"

# --- it refuses to act unasked -------------------------------------------
# With no tty and no --yes there is no consent to infer, and a verb that edits
# a config file must not guess. The suite runs with stdin on a pipe, which IS
# the no-tty case.
_rc=0; _o=$(mux setup claude </dev/null 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "it edited $SET without --yes and without a terminal"
[ -e "$SET" ] && fail "a refused run still wrote $SET"

# --- AND AT A TERMINAL IT ASKS, AND TAKES NO FOR AN ANSWER ---------------
# THE PROMPT HAD NEVER RUN. Every case here is on a pipe, which is the no-tty
# refusal above, so the interactive branch of the one verb that writes
# somebody else's config was reachable by no test at all. A pty is the only
# way in, the same device `mux help palette`, `mux sane` and latch's wait
# spinner need.
#
# ANSWERING `n` IS THE HALF THAT MATTERS. A prompt that asks and then applies
# regardless is worse than no prompt: the human has been told they had a
# choice. So this asserts the file is UNTOUCHED, not merely that something was
# printed, because a message proves only that a message was printed.
if [ -n "$T_PTY" ]; then
  _ask=$T/ask.log
  # THE ANSWER GOES THROUGH THE PTY, not through a redirect: `< file` replaces
  # stdin, so `[ -t 0 ]` is false and the verb takes the no-tty REFUSAL
  # instead of ever prompting. Cost one confusing run, and it is the whole
  # reason this case needs a pty rather than a pipe.
  # THE COMMAND RECORDS ITS OWN STATUS, because `script` does not propagate
  # the child's without GNU's `-e` and this suite must not key on a userland.
  # Reading it from the typescript's COMMAND_EXIT_CODE would be the same
  # mistake one layer over.
  printf 'n\n' | t_pty "$_ask" "env -u MUX_SHARE CLAUDE_CONFIG_DIR=$CDIR \
$HERE/bin/mux setup claude; printf %s \$? >$T/rc" >/dev/null 2>&1 || true
  _rc=$(cat "$T/rc" 2>/dev/null || echo 0)
  case $(cat "$_ask") in *'[y/N]'*) ;;
    *) fail "at a terminal, setup must ASK before editing somebody else's
config: [$(cat "$_ask")]" ;;
  esac
  [ ! -e "$SET" ] || fail "answering 'n' at the prompt WROTE $SET anyway,
which is worse than never asking: the human was told they had a choice"
  # NON-ZERO TOO, and asserted separately because they are different bugs: a
  # declined run that exits 0 tells a caller the wiring is in place.
  [ "$_rc" != 0 ] \
    || fail "answering 'n' exited 0, so anything scripting this verb reads a
decline as a successful wiring"
  # ... and `y` applies, or the prompt would be a refusal wearing a question.
  printf 'y\n' | t_pty "$T/ask2.log" "env -u MUX_SHARE \
CLAUDE_CONFIG_DIR=$CDIR $HERE/bin/mux setup claude" >/dev/null 2>&1 || true
  [ -e "$SET" ] || fail "answering 'y' at the prompt did not apply, so the
question has only one answer and the verb is unusable interactively"
  rm -f "$SET"
else
  printf 'note %s: no usable script(1), so the consent PROMPT is unchecked\n' \
    "$_name"
fi

# --- applying, into a file that already has content ----------------------
# The pre-existing hook and the unrelated key are the point of this fixture.
cat >"$SET" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "someone-elses"}]}]
  }
}
EOF
_o=$(mux setup claude --yes 2>&1) || fail "apply failed: $_o"
case $_o in
  *"backed up"*) ;;
  *) fail "no backup was reported, so the change is not reversible by copy:
[$_o]" ;;
esac
[ "$(ls "$CDIR"/settings.json.mux-* 2>/dev/null | wc -l)" -eq 1 ] \
  || fail "expected exactly one backup file"

# EVERY EVENT IS WIRED, to `mux agent-hook <Event>` and NOT to a state: the
# event-to-state mapping is mux's (0.52), and wiring that named states would
# put mux's vocabulary back in somebody else's file, where changing it needs a
# coordinated release.
for _e in $_events; do
  [ "$(j "any('mux agent-hook $_e' in h['command']
    for g in d['hooks']['$_e'] for h in g['hooks'])")" = True ] \
    || fail "$_e is not wired to 'mux agent-hook $_e'"
done
[ "$(j "any('agent-emit' in h['command']
  for v in d['hooks'].values() for g in v for h in g['hooks'])")" = False ] \
  || fail "it wired agent-emit, which names a STATE: that is the pre-0.52
contract and puts mux's own vocabulary back in the integrator's file"

# WHAT MUST SURVIVE. This is the assertion the verb exists to earn.
[ "$(j "d.get('theme')")" = dark ] || fail "an unrelated key was lost"
[ "$(j "any('someone-elses' in h['command']
  for g in d['hooks']['Stop'] for h in g['hooks'])")" = True ] \
  || fail "somebody else's hook on the same event was DESTROYED, which is
the only outcome here that cannot be undone by --remove"

# --- idempotent ----------------------------------------------------------
# A hook appended twice FIRES twice, and a second `working` after a turn ends is
# exactly the straggler this project spent two releases learning to discard.
_o=$(mux setup claude --yes 2>&1) || fail "second run failed: $_o"
case $_o in
  *"nothing to change"*) ;;
  *) fail "a second run was not a no-op: [$_o]" ;;
esac
[ "$(ls "$CDIR"/settings.json.mux-* 2>/dev/null | wc -l)" -eq 1 ] \
  || fail "a no-op run took another backup"
for _e in $_events; do
  [ "$(j "len([h for g in d['hooks']['$_e'] for h in g['hooks']
    if 'mux agent-hook' in h['command']])")" = 1 ] \
    || fail "$_e has more than one mux hook: it would fire twice"
done

# --- the skill is placed, which nothing else does ------------------------
_sk=$CDIR/skills/mux-agent/SKILL.md
[ -f "$_sk" ] || fail "the skill was not installed; mux ships the agent
instructions and until this verb nothing put them anywhere"
head -1 "$_sk" | grep -q '^---$' \
  || fail "the installed skill has no frontmatter, so it never triggers"

# --- --remove takes back only what mux added -----------------------------
_o=$(mux setup claude --remove --yes 2>&1) || fail "remove failed: $_o"
[ "$(j "any('mux agent-hook' in h['command']
  for v in d.get('hooks',{}).values() for g in v for h in g['hooks'])")" \
  = False ] || fail "--remove left mux's wiring behind"
[ "$(j "any('someone-elses' in h['command']
  for g in d['hooks']['Stop'] for h in g['hooks'])")" = True ] \
  || fail "--remove ate somebody else's hook"
[ "$(j "d.get('theme')")" = dark ] || fail "--remove lost an unrelated key"
[ -e "$_sk" ] && fail "--remove left the skill installed"
_o=$(mux setup claude --remove --yes 2>&1) || fail "second remove failed"
case $_o in
  *"nothing to change"*) ;;
  *) fail "removing twice was not a no-op: [$_o]" ;;
esac

# --- A FILE THAT DOES NOT PARSE IS LEFT ALONE ---------------------------
# Rewriting it from scratch would be the worst possible reading of
# "idempotent": the user has hand-edited JSON and broken it, and the one thing
# they need is for it to still be there when they look.
printf '{ this is not json' >"$SET"
_rc=0; _o=$(mux setup claude --yes 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "an unparseable settings file was accepted"
[ "$(cat "$SET")" = '{ this is not json' ] \
  || fail "an unparseable settings file was MODIFIED: [$(cat "$SET")]"
case $_o in
  *"does not parse"*) ;;
  *) fail "the refusal did not say the file does not parse: [$_o]" ;;
esac

pass
