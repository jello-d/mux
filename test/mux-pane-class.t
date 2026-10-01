#!/bin/sh
# test/mux-pane-class.t - the two PANE CLASS directives, `control` and
# `attention`, and mux's first producer of either option.
#
# WHY IT EXISTS AT ALL. `libexec/mux-agent` READS that option in two places to
# decide whether `mux agent send` may type into a pane, and until now NOTHING
# IN THE TREE WROTE IT. So the send policy shipped a root-owned vocabulary,
# `control:agent`, that no supported path could satisfy: a grant a human could
# write and nothing could ever match. That is this package's own rule about
# `mux setup claude`, met one surface over: a seam nobody can cross for you is
# not a seam, it is a gap.
#
# A DECLARATION, NEVER AN INVENTION, which is the line that keeps it safe. The
# creator of a pane says what the pane is for and mux records it; there is
# deliberately no way here to reclassify a pane somebody ELSE created, because
# that is the laundering move (promote a human's pane to `agent`, then send
# into it wherever a `control:agent` grant is in force).
#
# tmux is stubbed, so no server starts.
set -eu
_name=mux-pane-class
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf/layouts" "$T/conf/profiles.d" "$T/proj"

# A DISTINCT PANE ID PER PANE, and that is the whole reason this stub is not a
# copy of the one in mux-profile.t. Every other builder fixture in this suite
# answers `%1` to every pane_id query, so an assertion that the class landed
# on the right pane would pass equally against a hardcoded `%1`: a fixture
# whose value coincides with the obvious constant proves nothing, which
# mutation already caught here once.
#
# AND IT COUNTS PANES, NOT QUERIES, which is the correction that made it
# work. The first version incremented on every `pane_id` read and was wrong
# for a reason worth keeping: the builder asks SEVERAL times per pane (once
# for the session's first pane, then once per split), so query order is not
# pane order and the second pane answered `%3`. Modelling what tmux actually
# does is both stable and shorter: `pane_id` names the pane most recently
# CREATED, so the counter moves on a split or a respawn and the format query
# merely reads it. A stub looser than the tool fails in the direction that
# wastes most time, and here it would have been "the product marked the wrong
# pane" about a product that was right.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_width*) printf '200 49\n' ;;
*window_index*) printf '0\n' ;;
*split-window*|*respawn-pane*)
  _n=$(cat "$PANESEQ" 2>/dev/null || echo 0)
  printf '%s\n' "$((_n + 1))" >"$PANESEQ" ;;
*pane_id*) printf '%%%s\n' "$(cat "$PANESEQ" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; PANESEQ=$T/paneseq
export TMUXLOG PANESEQ
PATH=$T/bin:$PATH; export PATH

# build LAYOUT_TEXT -> run `mux go` against it, leaving the tmux log in place.
# `--no-agent` so the shipped agent command is irrelevant, `--no-attach` so
# nothing tries to take over this terminal.
build() {
  printf '%s\n' "$1" >"$T/conf/layouts/t.layout"
  printf 'layout  t\n' >"$T/conf/profiles.d/proj.profile"
  : >"$TMUXLOG"; : >"$PANESEQ"
  ( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" "$HERE/bin/mux" go --no-agent --no-attach ) 2>&1
}

# --- THE CLASS LANDS ON THE PANE THE DIRECTIVE QUALIFIES ------------------
# Two panes, and the class declared on the SECOND. `control` is a line that
# qualifies what came before (the shape `bottom` already uses) because
# `pane`'s argument is the COMMAND and a modifier cannot ride an arbitrary
# command line.
_o=$(build 'window main
pane
pane
control agent') || fail "a layout with a control directive failed: [$_o]"

# TWO ASSERTIONS, NOT ONE, and splitting them is what makes each cause
# individually killable: "it wrote nothing" and "it wrote against the wrong
# pane" are different defects, and one combined check reports whichever
# happened as the other. The corpus said so before this was split.
grep -q '@mux-control' "$TMUXLOG" \
  || fail "there was no @mux-control call at all. The directive parsed and
wrote nothing, which leaves the send policy's 'control:agent' grant
unreachable: a pane with no option reads as 'human', a REFUSAL, so the policy
looks like it is working."
grep -q 'set-option -p -t %2 @mux-control agent' "$TMUXLOG" \
  || fail "the class landed on the wrong pane. '%2' is the pane the directive
qualifies; a class recorded against a neighbour is this package's signature
failure, plausible and wrong and silent. The log said:
$(grep 'mux-control' "$TMUXLOG")"

# NO CORPUS RECORD REACHES THE NEXT ONE, and that is stated rather than
# papered over: setting the option on BOTH panes needs a second call, so no
# single-line mutation can produce it while the assertion above still passes.
# It is kept because it would fire on a real double-write, and claimed as
# nothing more than that.
grep -q 'set-option -p -t %1 @mux-control' "$TMUXLOG" \
  && fail "the class was set on the FIRST pane as well as the one it
qualifies. Only the pane above the directive is declared."
:

# --- ALL THREE WORDS ARE ACCEPTED, and the vocabulary is not a second copy
# of `libexec/mux-agent`'s `agent|hybrid`: that is the narrower set a POLICY
# may grant, since `human` is refused before the policy file is read at all.
# `human` is the default, so declaring it explicitly must still be legal: a
# layout that says out loud what it relies on is not an error.
for _c in human agent hybrid; do
  _o=$(build "window main
pane
control $_c") || fail "control $_c was refused: [$_o]"
  grep -q "@mux-control $_c" "$TMUXLOG" \
    || fail "control $_c parsed and then set nothing. A directive that
validates and does nothing is worse than a missing one, because the author
believes they declared something."
done

# --- THE REFUSALS, each with its own reason ------------------------------
# r WANT LAYOUT: refused non-zero, and the message SAYS WHICH, because one
# sentence covering several causes becomes wrong about one of them.
r() {
  _rw=$1
  _ro=$(build "$2") && fail "[$2] was accepted and should be refused"
  case $_ro in
  *"$_rw"*) ;;
  *) fail "refused without saying why: want [$_rw], got [$_ro]" ;;
  esac
}

# Nothing to qualify. The directive is positional by design, so a `control`
# with no pane above it is a layout whose author expected something else.
r "'control' with no pane" 'window main
control agent'

# AFTER `bottom` IS REFUSED FOR THE SAME REASON `pane` IS: the builder marks
# the pane it last created, and after a bottom that is no longer the pane a
# reader of the file would point at. Marking the wrong pane silently is the
# failure the first assertion in this file exists to prevent, so the ordering
# that would cause it is refused outright rather than guessed at.
r "'control' after 'bottom'" 'window main
pane
bottom  5-10
control agent'

# A WORD MUX DOES NOT KNOW IS LOUD, which is the same call `notify` makes and
# the same one `mux agent-hook` makes about an unknown event: an UNSET thing
# says nothing because nobody asked, but a NAMED one mux cannot honour is an
# author claiming a contract that does not exist. Silently defaulting to
# `human` here would be the worst available answer: the layout would read as
# a grant and behave as a refusal.
r "wants human|agent|hybrid" 'window main
pane
control supervisor'

# --- `attention` IS THE SECOND MARKER, AND A SEPARATE QUESTION -------------
# `control` answers who may TYPE here; `attention` answers whose attention is
# OWED. They are two because R3's escalation moves one without the other: a
# worker hands off to the human, ATTENTION moves, and the supervisor keeps its
# write access and can go on nudging. Fused, escalation would silently revoke
# the supervisor's ability to type at the exact moment it is handing over.
_o=$(build 'window main
pane
pane
attention agent') || fail "an attention directive failed: [$_o]"
grep -q 'set-option -p -t %2 @mux-attention agent' "$TMUXLOG" \
  || fail "the attention class did not land on the pane it qualifies. The log
said: $(grep 'mux-attention' "$TMUXLOG" || echo '(no call at all)')"

# BOTH ON ONE PANE, which is the combination the design rests on and the one a
# shared parser arm could silently collapse: a worker its supervisor may type
# into AND that the human should still see.
_o=$(build 'window main
pane
control agent
attention human') || fail "declaring both failed: [$_o]"
grep -q '@mux-control agent' "$TMUXLOG" \
  || fail "control was lost when attention was declared beside it"
grep -q '@mux-attention human' "$TMUXLOG" \
  || fail "attention was lost when control was declared beside it"

# AND A REFUSAL NAMES THE DIRECTIVE THAT CAUSED IT. The two share one parser
# arm, which is not fusing the concepts (they are read by different
# consumers) but it IS the one place a shared arm goes wrong: reporting
# 'control' for an `attention` mistake sends the reader to the wrong line.
r "'attention' with no pane" 'window main
attention agent'
r "'attention' wants human|agent|hybrid" 'window main
pane
attention supervisor'

pass
