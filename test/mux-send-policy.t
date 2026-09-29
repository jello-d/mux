#!/bin/sh
# test/mux-send-policy.t - who may type into a pane mux cannot vouch for.
#
# THE SECURITY PROPERTY IS "THE GOVERNED PARTY CANNOT GRANT ITSELF THE
# PERMISSION", and every assertion here exists to hold that down. mux runs as
# the agent's own user, so a policy that user can write is not a policy -- and
# the failure would be silent and total: the agent edits one line and mux
# starts typing into panes that are waiting on a human.
#
# So the writability check is tested from BOTH directions, which is the habit
# this suite has had to learn repeatedly: a refusal that never fires reads
# exactly like a policy that is working.
set -eu
_name=mux-send-policy
. "$(dirname "$0")/harness_lib"

. "$HERE/libexec/mux-send-policy_lib"

POL=$T/etc/send-policy
mkdir -p "$T/etc"
MUX_SEND_POLICY_FILE=$POL; export MUX_SEND_POLICY_FILE

# The suite cannot make a file root-owned without sudo, so "not writable by
# this user" is produced with mode bits instead. That is the same question the
# code asks -- `[ -w ]` -- so the fixture exercises the real predicate rather
# than a stand-in for it.
seal() { chmod 0444 "$POL"; chmod 0555 "$T/etc"; }
unseal() { chmod 0755 "$T/etc"; chmod 0644 "$POL"; }
t_trap 'chmod 0755 "$T/etc" 2>/dev/null || true'

# CLASS DEFAULTS TO `agent` in these helpers, because a human-controlled pane
# never reaches this file at all -- `send` refuses it before the policy is
# consulted, so "never" is structural rather than a token an operator has to
# remember. That gate is asserted in test/mux-agent.t, where it lives.
allow() { mux_send_allowed "$2" "$3" "$4" "$5" "${6:-agent}"; }
yes() { allow "$@" || fail "$1: should have been permitted"; }
no()  { ! allow "$@" || fail "$1: should have been REFUSED"; }

# --- with no policy at all, nothing is permitted --------------------------
# The default has to be the safe one, because the common case is a box where
# nobody has ever thought about this.
no no-file blocked global api reviewer
[ -n "$(mux_send_policy_why)" ] || fail "no policy, but nothing said why"

# AND IT IS SILENT ABOUT IT. Missing is the common case -- it is every box
# where nobody has thought about this -- so the check must not spew `cannot
# open` on stderr each time. Asserted with the directory SEALED, so the
# existence test is the only guard that can produce the refusal and its
# removal is visible rather than covered by the writability checks.
chmod 0555 "$T/etc"
_o=$( (mux_send_allowed blocked global api reviewer) 2>&1 >/dev/null || true)
[ -z "$_o" ] || fail "a missing policy wrote to stderr: [$_o]
That is the common case on every box, so it has to be quiet."
chmod 0755 "$T/etc"

# --- A POLICY THIS USER CAN WRITE IS NOT A POLICY -------------------------
# The load-bearing assertion. An agent with a shell tool edits a user-owned
# file in one line, so obeying one would be a permission the governed party
# granted itself.
# THE DIRECTORY IS SEALED FOR THIS CASE, so only the FILE check can produce
# the refusal. Left writable, the directory check covers for it and removing
# the file check entirely still passes -- two guards for one condition, which
# means neither is individually killable. Mutation said so: deleting the line
# that makes this whole mechanism work changed nothing.
printf 'send-blocked *\n' >"$POL"
chmod 0644 "$POL"; chmod 0555 "$T/etc"
no writable-file blocked global api reviewer
case "$(mux_send_policy_why)" in
*writable*) ;;
*) fail "a writable policy was ignored without saying so: it must be LOUD,
because the human who wrote it believes it applies: [$(mux_send_policy_why)]" ;;
esac

# ... and the DIRECTORY too, with the FILE sealed for the same reason in
# reverse: being unable to write a file is no protection when you can replace
# it, and this case must be the only one that can catch that.
chmod 0755 "$T/etc"; chmod 0444 "$POL"
no writable-dir blocked global api reviewer
case "$(mux_send_policy_why)" in
*directory*) ;;
*) fail "a policy in a user-writable directory was accepted or the reason was
wrong: [$(mux_send_policy_why)]" ;;
esac

# --- sealed: now it is obeyed ---------------------------------------------
seal
[ -z "$(mux_send_policy_why)" ] \
  || fail "a sealed policy still reported a reason it was not in force:
[$(mux_send_policy_why)]"
yes sealed-star blocked global api reviewer

# --- the two directives are SEPARATE grants -------------------------------
# "This worker may have its prompts answered" and "this worker may be typed at
# blind" are different permissions; allowing one must not allow the other.
unseal; printf 'send-blocked *\n' >"$POL"; seal
yes blocked-granted blocked global api reviewer
no  unknown-not-granted unknown global api reviewer
unseal; printf 'send-unknown *\n' >"$POL"; seal
yes unknown-granted unknown global api reviewer
no  blocked-not-granted blocked global api reviewer

# --- scope: partition, session, and the one that matters, WINDOW ----------
# An orchestrator above mux spawns a WINDOW per worker in the project's
# session, so `session:` alone grants every worker in that project at once.
# Per-window is the granularity a fleet actually has.
unseal; printf 'send-blocked partition:work\n' >"$POL"; seal
yes part-match   blocked work api reviewer
no  part-nomatch blocked global api reviewer

unseal; printf 'send-blocked session:api\n' >"$POL"; seal
yes sess-match   blocked global api reviewer
no  sess-nomatch blocked global other reviewer

unseal; printf 'send-blocked window:reviewer\n' >"$POL"; seal
yes win-match   blocked global api reviewer
no  win-nomatch blocked global api builder

# --- EVERY TOKEN ON A LINE MUST MATCH -------------------------------------
# The conjunction is what makes "one worker in one project" expressible at
# all. If tokens were alternatives instead, this line would grant every window
# called `reviewer` in every project, which is the opposite of what it reads
# like.
unseal; printf 'send-blocked session:api window:reviewer\n' >"$POL"; seal
yes both-match    blocked global api reviewer
no  wrong-window  blocked global api builder
no  wrong-session blocked global other reviewer

# --- control: the class is a scope token too -------------------------------
# WHO CONTROLS THE PANE is a different question from where it is, and it is
# the one that decides whether answering a prompt usurps a human. Granting the
# whole `agent` class is what makes a village workable: eight workers with
# generated names cannot each get a line in a root-owned file before vicus is
# allowed to operate.
unseal; printf 'send-blocked control:agent\n' >"$POL"; seal
yes class-agent  blocked global api reviewer agent
no  class-hybrid blocked global api reviewer hybrid

# HYBRID IS ITS OWN CLASS, and grantable separately. Folding it into `human`
# was the first design and was wrong in the dangerous direction: the only way
# to grant a hybrid pane would then have been a human grant, so expressing the
# MIDDLING case would have forced the door open for the strictest one.
unseal; printf 'send-blocked control:hybrid session:api\n' >"$POL"; seal
yes hybrid-scoped    blocked global api reviewer hybrid
no  hybrid-elsewhere blocked global other reviewer hybrid
no  agent-not-hybrid blocked global api reviewer agent

# A BROAD GRANT STILL DOES NOT REACH A HUMAN PANE, because this file is never
# consulted for one. Asserted here as the honest limit of what this function
# can promise: it would happily match, which is exactly why the gate is not
# in it.
unseal; printf 'send-blocked *\n' >"$POL"; seal
yes star-agent  blocked global api reviewer agent
yes star-hybrid blocked global api reviewer hybrid

# --- a directive with NO scope grants nothing -----------------------------
# `send-blocked` alone reads like "allow it", and reading it that way would
# turn a truncated line into a systemwide permission.
unseal; printf 'send-blocked\n' >"$POL"; seal
no bare-directive blocked global api reviewer

# --- a name is a STRING, never a pattern ----------------------------------
# A window called `*` must not grant itself everything, and one called
# `partition:work` must not grant that partition.
unseal; printf 'send-blocked window:reviewer\n' >"$POL"; seal
no star-window blocked global api '*'
unseal; printf 'send-blocked session:api\n' >"$POL"; seal
no crafted-name blocked global 'partition:work' reviewer

# --- an empty or comment-only policy permits nothing ----------------------
unseal; printf '# just a comment\n\n' >"$POL"; seal
no comments-only blocked global api reviewer
unseal; : >"$POL"; seal
no empty-file blocked global api reviewer

# --- an unrelated directive is not a grant --------------------------------
unseal; printf 'send-everything *\nsend-blockedx *\n' >"$POL"; seal
no unrelated blocked global api reviewer

pass
