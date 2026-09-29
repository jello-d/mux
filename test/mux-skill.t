#!/bin/sh
# test/mux-skill.t - `mux skill`, and the agent instructions it ships.
#
# TWO THINGS ARE UNDER TEST AND THE SECOND IS THE UNUSUAL ONE. The verb has to
# resolve, refuse and not read outside its own directory. But the CONTENT has
# to stay true: this is the only documentation an agent actually reads, and one
# that names a verb or a flag this mux does not have teaches a call that fails.
# It is installed once into somebody else's config directory and then nobody
# looks at it again, so drift there is permanent and invisible.
#
# So the verbs and flags it mentions are checked AGAINST THE SOURCE, the same
# way mux-check derives its key list from the tmux fragment rather than
# restating it.
#
# AND THERE ARE TWO CONVENTIONS OVER ONE DOCUMENT: the vendor-neutral
# `AGENTS.md` a repository carries, and one harness's `SKILL.md` with YAML
# frontmatter. A second copy of the text would drift, so the body is the file
# and the frontmatter is data beside it -- which is asserted here, because a
# single source is only worth anything if something notices when it stops
# being single.
set -eu
_name=mux-skill
. "$(dirname "$0")/harness_lib"

mux() { env -u MUX_SHARE "$HERE/bin/mux" "$@"; }

# --- it prints the shipped skill ------------------------------------------
_o=$(mux skill) || fail "mux skill failed: $_o"
case $_o in
'---'*) ;;
*) fail "the skill must open with YAML frontmatter, got: $(printf '%s' "$_o" \
  | head -1)" ;;
esac
printf '%s\n' "$_o" | grep -q '^name: mux-agent$' \
  || fail "the frontmatter has no name:"
printf '%s\n' "$_o" | grep -q '^description:' \
  || fail "the frontmatter has no description: -- which is what an agent
harness matches on to decide the skill is relevant, so without it the file is
installed and never triggers"

# AND THE FRONTMATTER IS VALID YAML, with a description that survives FOLDING.
# It is long enough to need a folded scalar to stay inside 80 columns, and a
# fold a harness cannot parse fails in the worst way available: the file
# installs, nothing errors, and the skill never triggers. Skipped where pyyaml
# is absent rather than assumed present.
if python3 -c 'import yaml' 2>/dev/null; then
  printf '%s\n' "$_o" >"$T/skill.md"
  MUX_T_SKILL=$T/skill.md "$HERE/test/frontmatter" \
    || fail "the frontmatter did not parse as a harness would read it"
fi

# --- THE TWO FORMS ARE ONE DOCUMENT ---------------------------------------
_plain=$(mux skill --agents-md) || fail "mux skill --agents-md failed"
case $_plain in
'---'*) fail "the AGENTS.md form carries YAML frontmatter, which a generic
harness reads as content. The frontmatter belongs only in the composed form" ;;
esac

# THE COMPOSED FORM ENDS WITH THE BODY, VERBATIM. This is what makes the
# single source observable rather than merely true today: any second copy of
# the text, or any transformation on the way out, shows up here.
_o=$(mux skill)
printf '%s\n' "$_plain" >"$T/plain"
printf '%s\n' "$_o" | tail -n "$(wc -l <"$T/plain")" >"$T/body"
cmp -s "$T/body" "$T/plain" || fail "the composed skill's body is not the
AGENTS.md form. They must be one document with one dress changed, or the two
conventions will come to disagree about what mux refuses."

# ... and BEGINS with the frontmatter file, between markers. Asserted from the
# shipped file rather than a copy typed here, for the same reason.
{ echo '---'; cat "$HERE/share/skills/mux-agent/frontmatter.yaml"
  echo '---'; } >"$T/want-front"
printf '%s\n' "$_o" | head -n "$(wc -l <"$T/want-front")" >"$T/got-front"
cmp -s "$T/got-front" "$T/want-front" || fail "the composed skill does not
open with the shipped frontmatter"

# NOTHING SITS BETWEEN THEM but the one blank line markdown wants.
_nf=$(wc -l <"$T/want-front"); _nb=$(wc -l <"$T/plain")
_nt=$(printf '%s\n' "$_o" | wc -l)
[ "$_nt" -eq "$((_nf + _nb + 1))" ] || fail "the composed skill is $_nt lines,
not the $_nf of frontmatter plus a blank plus the $_nb of body: something is
being injected between them"

# AN ALWAYS-LOADED DOCUMENT MUST SAY WHEN IT DOES NOT APPLY. A skill is matched
# on its description and invoked on demand, so its premise holds whenever it is
# read; an AGENTS.md is in context for every turn in that repository, including
# turns with no tmux anywhere. An unconditional premise is a false one.
printf '%s\n' "$_plain" | grep -q 'TMUX' \
  || fail "the AGENTS.md form never says how to tell whether it applies,
so an agent in a repo with no tmux reads it as instructions anyway"

# --- A MISSING FRONTMATTER IS FATAL, NOT AN OMISSION ----------------------
# A SKILL.md with no frontmatter installs fine, errors nothing, and never
# triggers -- the worst failure available to a file whose only job is to be
# matched. Splitting the document is what made that partial install possible,
# so it has to be refused here rather than emitted.
mkdir -p "$T/share/skills/bare"
echo '# just a body' >"$T/share/skills/bare/AGENTS.md"
bare() { MUX_SHARE=$T/share "$HERE/bin/mux" "$@"; }
_rc=0; bare skill bare >"$T/out" 2>"$T/err" || _rc=$?
[ "$_rc" = 1 ] || fail "a skill with no frontmatter.yaml must fail, got $_rc"

# STDOUT AND STDERR ARE ASSERTED SEPARATELY, because the obvious single
# assertion is VACUOUS and was: with the guard deleted, `cat` fails on the
# missing file, prints a message CONTAINING the path -- so any test grepping
# the combined output for "frontmatter" passes, and exit 1 comes free from
# `set -e`. Mutation said so. What actually differs is that the guard emits
# NOTHING on stdout, where its absence emits a truncated document.
[ ! -s "$T/out" ] || fail "a refusal put $(wc -c <"$T/out") bytes on stdout:
a half-written skill is the one outcome that installs cleanly and never fires
$(cat "$T/out")"
grep -q 'cannot be assembled' "$T/err" || fail "the refusal did not say the
skill form could not be assembled, so it is indistinguishable from whatever
error a missing file happens to produce: [$(cat "$T/err")]"

# ... and the AGENTS.md form is UNAFFECTED, because it needs no frontmatter.
# Two forms sharing a body must not share each other's preconditions.
_o=$(bare skill --agents-md bare) || fail "--agents-md should still work"
[ "$_o" = '# just a body' ] || fail "--agents-md printed [$_o]"

# --- refusals --------------------------------------------------------------
_rc=0; _o=$(mux skill nosuchskill 2>&1) || _rc=$?
[ "$_rc" = 1 ] || fail "an unknown skill should exit 1, got $_rc"
case $_o in
*"have: mux-agent"*) ;;
*) fail "the refusal did not name what there IS, so a typo looks like a
missing feature: [$_o]" ;;
esac

# A NAME BECOMES A PATH, so it is checked before it is one. Without this the
# argument is a traversal and the verb happily prints any readable file.
for _bad in ../../etc/passwd /etc/passwd 'mux agent' UPPER -dash; do
  _rc=0; _o=$(mux skill "$_bad" 2>&1) || _rc=$?
  [ "$_rc" = 2 ] || fail "[$_bad] should be a usage error (2), got $_rc"
  case $_o in
  *root:*|*bin/sh*) fail "a traversal READ A FILE: [$_o]" ;;
  esac
done

_rc=0; mux skill --help >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "--help should exit 0, got $_rc"

# --- IT IS NOT UNDER `mux agent` ------------------------------------------
# Everything there promises ONE JSON OBJECT on stdout, including on failure. A
# verb printing markdown would make that promise a convention with an
# exception, which is not a contract.
_rc=0; _o=$(mux agent skill 2>&1) || _rc=$?
case $_o in
*'"status"'*) ;;
*) fail "\`mux agent skill\` answered something other than JSON, so the agent
surface no longer answers JSON to everything: [$_o]" ;;
esac

# --- THE CONTENT MATCHES THIS MUX -----------------------------------------
# Every verb the skill teaches must exist. Read out of the dispatcher rather
# than listed here: a copy would drift in exactly the way this is checking
# for.
_skill=$(mux skill)
_sub=$(awk '/^case \$_verb in$/,/^esac$/' "$HERE/libexec/mux-agent" \
  | grep -oE '^[a-z][a-z|-]*\)' | tr -d ')' | tr '|' '\n' | grep .)
[ -n "$_sub" ] || fail "no sub-verbs discovered; the scrape is broken and this
guard proves nothing"
for _v in $_sub; do
  printf '%s\n' "$_skill" | grep -q "mux agent $_v" \
    || fail "the skill never mentions \`mux agent $_v\`, so an agent
reading it does not know the verb exists. Teach it, or take the verb out."
done

# ... and every verb it CLAIMS must exist, which is the direction that breaks a
# call rather than merely hiding one.
for _v in $(printf '%s\n' "$_skill" | grep -oE 'mux agent [a-z-]+' \
    | awk '{print $3}' | sort -u); do
  case " $(printf '%s\n' "$_sub" | tr '\n' ' ') " in
  *" $_v "*) ;;
  *) fail "the skill teaches \`mux agent $_v\`, which this mux does not
have. An agent following it would make a call that fails." ;;
  esac
done

# THE FLAGS IT NAMES MUST PARSE. A skill that teaches a flag the verb rejects
# is worse than one that omits it: the agent composes the call, gets exit 2,
# and has no way to tell a typo from a version skew.
for _f in $(printf '%s\n' "$_skill" | grep -oE '(^|[ `])--[a-z][a-z-]*' \
    | tr -d ' `' | sort -u); do
  grep -q -- "$_f)" "$HERE/libexec/mux-agent" \
    || fail "the skill names $_f, which libexec/mux-agent does not
parse"
done

# THE SCOPE CLAIM IS CHECKED PER VERB, because the flag sweep above cannot.
# It asserts a flag is parsed SOMEWHERE in the dispatcher, so `--partition`
# passed while `mux agent status` rejected it outright -- and `--all` was parsed
# by status and then never read, which no name-based check can see at all. The
# skill says both verbs take both flags, in the same breath as calling a
# partition an isolation boundary, so that sentence is asserted against the
# verbs themselves.
for _v in status peers; do
  for _f in --all "--partition global"; do
    # shellcheck disable=SC2086   # a flag and its value, split
    _o=$(mux agent $_v $_f 2>&1) || true
    case $_o in
    *'"status":"usage"'*) fail "the skill says \`mux agent $_v\` takes
$_f, and the verb answers a usage error: [$_o]" ;;
    esac
  done
done

# THE STATES IT NAMES ARE THE STATES MUX EMITS. This one has bitten the
# project before at one remove: the doctor gave advice that could not come
# true because a contract had moved under it.
for _st in blocked working idle; do
  printf '%s\n' "$_skill" | grep -q "$_st" \
    || fail "the skill never mentions the state $_st"
done

# THE EXIT CODES IT DOCUMENTS ARE MUX'S FOUR. The absence of every other one
# is load-bearing -- latch attributes 126, 127 and 255 to the shell and to ssh
# precisely because mux never emits them -- so a skill teaching a fifth would
# be teaching a caller to mis-attribute a transport failure.
for _s in ok refused timed-out usage no-such-name; do
  printf '%s\n' "$_skill" | grep -q "$_s" \
    || fail "the skill does not document the status \`$_s\`"
done

# AND THE RULE THAT MATTERS IS IN IT. Everything else here is upkeep; this is
# the reason the file ships at all.
printf '%s\n' "$_skill" | grep -qi 'never answer' \
  || fail "the skill does not tell an agent never to answer another
agent's permission prompt, which is the one thing it exists to say"
printf '%s\n' "$_skill" | grep -q -- '--answer-prompt' \
  || fail "the skill does not explain the override it must not take
without one"
printf '%s\n' "$_skill" | grep -qi 'tell the human' \
  || fail "the skill does not say what to do INSTEAD, and a rule with no
alternative is one an agent works around"

pass
