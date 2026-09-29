#!/bin/sh
# test/mux-skill.t - `mux skill`, and the skill it ships.
#
# TWO THINGS ARE UNDER TEST AND THE SECOND IS THE UNUSUAL ONE. The verb has to
# resolve, refuse and not read outside its own directory. But the CONTENT has
# to stay true: a skill is the only documentation an agent actually reads, and
# one that names a verb or a flag this mux does not have teaches a call that
# fails. It is installed once into somebody else's config directory and then
# nobody looks at it again, so drift there is permanent and invisible.
#
# So the verbs and flags it mentions are checked AGAINST THE SOURCE, the same
# way mux-check derives its key list from the tmux fragment rather than
# restating it.
set -eu
_name=mux-skill
. "$(dirname "$0")/lib.sh"

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
	MUX_T_SKILL=$T/skill.md python3 "$HERE/test/frontmatter.py" \
		|| fail "the frontmatter did not parse as a harness would read it"
fi

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
