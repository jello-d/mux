#!/bin/sh
# mux-announce.t - WHICH state changes are worth interrupting a human for.
#
# THESE ASSERTIONS ARE NOT NEW. They lived in `test/mux-notify.t`, driven
# through `mux-agent-state-emit`, because emit was what raised the banner. The
# rules did not change when the raising moved to `mux-desktop-notifier`: the
# DECISION still has to be made on the box with the tmux server, since every
# fact it needs is a property of a pane there at the moment it changed, and a
# daemon reading the far end of an ssh pipe cannot ask about any of them.
#
# WHY EMIT COULD NOT KEEP IT. A hook raises on the box the AGENT runs on,
# which is the one machine that may have nobody sitting at it: every blocked
# LATCHED session popped a toast on a remote desktop for as long as latch has
# existed. Structural, and unfixable from inside a hook.
#
# DRIVEN AGAINST THE LIB, not through `mux agent stream`. The stream is a
# long-lived process that speaks on a timer, so every one of these would have
# become a multi-second race for no gain; the policy is a pure function of
# (old rows, new rows) plus three tmux questions, and that is exactly what is
# called here. The end-to-end path is covered live instead, which is the only
# way to prove the stream asks tmux at all.
_name=mux-announce
. "$(dirname "$0")/harness_lib"

. "$HERE/lib/mux-json_lib"
. "$HERE/lib/mux-agent-state_lib"
. "$HERE/lib/mux-agent-announce_lib"

mkdir -p "$T/bin" "$XDG_RUNTIME_DIR/mux/agent-state/global"
# The gate asks three questions and this answers each from the environment, so
# a case states its own world. ONE ARM PER QUESTION, which this suite has paid
# for before: a stub looser than the tool makes the failing case pass.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*pane_active*)        printf '%s\n' "${FAKE_VIS:-0}" ;;
*mux-notify-always*)  printf '%s\n' "${FAKE_ALWAYS:-}" ;;
*mux-attention*)      printf '%s\n' "${FAKE_ATTN:-}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
PATH="$T/bin:$PATH"
# EXPORTED, because the stub is a separate process and reads its answers from
# the ENVIRONMENT: a bare assignment sets a shell variable the stub cannot
# see, so every case would have run against the defaults and the visibility
# cases would have passed for the wrong reason. Found by one of them failing.
FAKE_VIS=0 FAKE_ALWAYS= FAKE_ATTN=
export FAKE_VIS FAKE_ALWAYS FAKE_ATTN

# One record so the gate can resolve a pane for `api`. The session is LAST, as
# the format requires; `agent_rec` owns the field order so a fixture cannot
# drift from it.
agent_rec "$XDG_RUNTIME_DIR/mux/agent-state/global/p1" idle %1 100 api -

ann() {   # <old-rows> <new-rows> -> the announce lines
  mux_announce_lines "$1" "$2"
}
kinds() {   # the kinds announced, space separated
  printf '%s\n' "$1" | sed -n 's/.*"kind":"\([a-z]*\)".*/\1/p' | tr '\n' ' '
}

# --- A TURN ENDING IS NEWS -------------------------------------------------
_o=$(ann 'global working api' 'global blocked api')
[ -n "$_o" ] || fail "working -> blocked announced nothing, which is the one
transition a human most needs told about: an agent is waiting at a prompt"
case $_o in *'"kind":"blocked"'*) ;;
*) fail "the wrong kind for a blocked pane: [$_o]" ;; esac
case $_o in *'"session":"api"'*) ;;
*) fail "the announcement does not name the session, so a banner cannot
either: [$_o]" ;; esac

_o=$(ann 'global working api' 'global idle api')
case $(kinds "$_o") in 'finished '*) ;;
*) fail "working -> idle must announce a finished turn: [$_o]" ;; esac

# --- AND STARTING ONE IS NOT ----------------------------------------------
# That transition is YOU, not the agent, so a banner would announce your own
# keystroke back at you.
[ -z "$(ann 'global idle api' 'global working api')" ] \
  || fail "idle -> working announced something: that transition is the human"

# --- NOR IS A SAME-STATE RE-EMIT ------------------------------------------
# A beat refreshes a record without changing it, at tool-call rate. Announcing
# on those would ring once per tool call for the whole turn.
[ -z "$(ann 'global working api' 'global working api')" ] \
  || fail "a same-state re-emit announced something"
[ -z "$(ann 'global blocked api' 'global blocked api')" ] \
  || fail "a still-blocked session announced again"

# --- `humming` IS THE TURN ENDING, AND IT IS THE ONE RULE THAT HAD TO MOVE -
# emit never wrote `humming`: it wrote `idle`, and a READER derives humming
# from the sidecar. So emit only ever saw working -> idle. The stream sees the
# DERIVED state, so a turn that left background work goes working -> humming
# and then humming -> idle later. Announcing on neither edge loses the banner
# for every such turn; announcing on both rings twice for one event. The turn
# ends on the first edge; the second is the JOB finishing, which is not news.
case $(kinds "$(ann 'global working api' 'global humming api')") in
'finished '*) ;;
*) fail "working -> humming announced nothing: every turn that left
background work would lose its banner, which is precisely the case the
humming state was added to make visible" ;;
esac
[ -z "$(ann 'global humming api' 'global idle api')" ] \
  || fail "humming -> idle announced something: the turn had already ended on
the previous edge, so this rings a second time for one event"

# --- NOT WHEN YOU ARE LOOKING AT IT ---------------------------------------
# The bar already shows it, and a banner is an INTERRUPT. This is the fact a
# remote daemon could never have: a latch IS the human's live view of that
# pane, so it holds across a transport too.
FAKE_VIS=1
[ -z "$(ann 'global working api' 'global blocked api')" ] \
  || fail "the pane the human is watching raised a banner anyway"

# --- UNLESS THE LAYOUT SAYS ALWAYS ----------------------------------------
FAKE_ALWAYS=1
[ -n "$(ann 'global working api' 'global blocked api')" ] \
  || fail "\`notify always\` did not override visibility, so the directive
does nothing"
FAKE_ALWAYS=

# --- AND NEVER FOR A PANE WHOSE ATTENTION IS A WORKER'S -------------------
# A banner is addressed to somebody. A worker answers to its supervisor, which
# already knows: it is the thing that is waiting. A village of them would ring
# the human repeatedly for decisions they were never going to make.
FAKE_VIS=0 FAKE_ATTN=agent
[ -z "$(ann 'global working api' 'global blocked api')" ] \
  || fail "a worker's pane rang the human, which is the inversion the
attention marker exists to prevent"

# AND IT OVERRIDES `notify always`, deliberately: that directive answers "even
# when I am looking at it", a question about VISIBILITY, while this one
# answers whether the banner is addressed to this human at all. A layout
# saying `notify always` on a worker is describing the window, not
# volunteering the human.
FAKE_ALWAYS=1
[ -z "$(ann 'global working api' 'global blocked api')" ] \
  || fail "\`notify always\` on a worker overrode the attention marker"
FAKE_ALWAYS= FAKE_ATTN=

# `hybrid` MEANS BOTH, so it announces: a pane the human may also be asked
# about must not go quiet, and failing toward the human is the direction that
# cannot invert the signal.
FAKE_ATTN=hybrid
[ -n "$(ann 'global working api' 'global blocked api')" ] \
  || fail "a hybrid pane went quiet, so expressing the middling case silenced
the human"
FAKE_ATTN=

# --- A SESSION SEEN FOR THE FIRST TIME ANNOUNCES NOTHING ------------------
# There is no previous state, so there is no transition. Without this a
# daemon connecting, or a stream respawning after a drop, would announce every
# finished turn on the box at once.
[ -z "$(ann '' 'global idle api')" ] \
  || fail "a session with no previous state announced: a reconnect would
toast every finished turn on the box"
[ -z "$(ann 'global working other' 'global idle api')" ] \
  || fail "a session absent from the previous answer announced"

# --- SCOPED, WHEN THE CALLER ASKED FOR ONE PARTITION ----------------------
# The stream filters its document by `--partition`, so announcing outside that
# scope would have it speak about something it does not report.
_spart=global
[ -n "$(ann 'global working api' 'global blocked api')" ] \
  || fail "the caller's own partition was filtered out"
[ -z "$(ann 'work working api' 'work blocked api')" ] \
  || fail "a partition outside the requested scope announced"
_spart=

# --- AND A RECORD WHOSE PANE HAS GONE STILL ANNOUNCES ---------------------
# The transition is real and nothing can be asked about where it happened, so
# it is announced: failing toward the human is the direction that cannot
# invert the signal, and the alternative is silence about a prompt that may
# genuinely be waiting.
[ -n "$(ann 'global working nopane' 'global blocked nopane')" ] \
  || fail "a session with no resolvable pane went silent, so a record that
outlived its pane can never be announced"

pass
