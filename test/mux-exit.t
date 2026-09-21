#!/bin/sh
# test/mux-exit.t - the EXIT CODE contract, which is what a remote or automated
# caller reads instead of the prose.
#
# mux uses exactly three codes and nothing else:
#
#   0   answered, or succeeded
#   1   refused for a stated reason (a guard fired, drift was found, no such
#       session). Something is on stderr saying why.
#   2   usage error, or a verb this mux does not know
#
# THE ABSENCE OF EVERYTHING ELSE IS THE LOAD-BEARING PART, and it is why this
# file exists rather than a paragraph in the man page. `ssh` returns 255 for its
# OWN errors and otherwise passes the remote command's status through, and a
# shell returns 126 and 127 for not-executable and not-found. Because mux never
# produces any of those, a caller can attribute them to the transport or the
# shell with certainty:
#
#   ssh host mux agent-list
#     0        an answer (possibly empty, which is a valid answer)
#     1        mux refused, for a reason on stderr
#     2        that mux is too old to know the verb
#     255      the transport, not mux
#     127      mux is not on that box's PATH
#
# That attribution is what the planned `latch` supervisor classifies retries on,
# and it is also how a fleet mid-upgrade stops reading as half-broken: `2` is a
# version answer, not a failure. None of it holds if some verb ever returns 3.
#
# test/lint.t carries the mechanical half (no literal `exit N` above 2 anywhere
# in shipped code), which holds the rule against code nobody has written yet.
# This half pins what today's verbs actually do.
set -eu
_name=mux-exit
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/conf/tmux" "$T/proj" "$T/empty"

# A server with nothing in it: every "no such session" path is then reached by
# the real front end rather than faked.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*has-session*|*list-sessions*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf 'scan %s 1\n' "$T" >"$T/conf/partitions/global.partition"

# Outside tmux, and with XDG_CONFIG_HOME pinned INTO the scratch dir so
# TMUX_CONF resolves deterministically. Without that, reload finds the real
# ~/.config/tmux/tmux.conf and its refusal path is never reached -- which is
# exactly what happened while surveying these codes by hand.
#
# EDITOR is neutered and stdin is /dev/null for EVERY invocation. The sweep
# below drives `mux edit`, which opens an editor, and the picker, which reads a
# choice. Without both guards this file inherited the ambient $EDITOR and hung
# NONDETERMINISTICALLY -- it timed out once and then passed in 5s with nothing
# changed, which is worse than a consistent failure.
# `|| _r=$?` is load-bearing, not decoration: under set -eu a bare non-zero
# statement aborts the whole script, so the FIRST refusal case would kill this
# file before it could report the code it just measured. Every case here is
# expected to fail, so this is the common path, not the edge.
rc() {
	_r=0
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
		XDG_CONFIG_HOME="$T/conf" XDG_RUNTIME_DIR="$T/run" \
		MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		EDITOR=/bin/true VISUAL=/bin/true \
		"$HERE/bin/mux" "$@" </dev/null ) >/dev/null 2>&1 \
		|| _r=$?
	echo "$_r"
}
# Same, but keeping stderr so "a refusal SAYS why" is checkable.
#
# `2>&1 >/dev/null` is deliberately in THAT order and is not the usual
# both-to-the-same-place idiom: stderr is pointed at the capture FIRST,
# then stdout is discarded, so what comes back is the refusal and not the
# answer. Reversing it would discard both, which is what SC2069 assumes
# you meant.
# shellcheck disable=SC2069
err() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX PATH="$T/bin:$PATH" \
		XDG_CONFIG_HOME="$T/conf" XDG_RUNTIME_DIR="$T/run" \
		MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		EDITOR=/bin/true VISUAL=/bin/true \
		"$HERE/bin/mux" "$@" </dev/null ) 2>&1 >/dev/null || true
}
is() {   # <want> <got> <what>
	[ "$1" = "$2" ] || fail "$3: want exit $1, got $2"
}

# --- 0: it answered ------------------------------------------------------
# Including the cases where the answer is "nothing". An empty answer is an
# ANSWER, and the distinction between that and a failure is the whole point of
# the contract: a quiet host must not read as a broken one.
is 0 "$(rc --version)"        "mux --version"
is 0 "$(rc -V)"               "mux -V"
is 0 "$(rc help)"             "mux help"
is 0 "$(rc help agents)"      "mux help agents"
is 0 "$(rc ls)"               "mux ls with no sessions"
is 0 "$(rc agent-list)"       "mux agent-list with no agents"
is 0 "$(rc agent-summary)"    "mux agent-summary with no agents"
is 0 "$(rc agent-doctor)"     "mux agent-doctor with no state"
is 0 "$(rc views)"            "mux views"
is 0 "$(rc why unknownname)"  "mux why on an unresolvable name"

# `why` answering 0 for a name that does not resolve is DELIBERATE: it is a
# diagnostic, and "here is why that name resolves to nothing" is a successful
# answer to the question asked. Pinned so it is not quietly changed into an
# assertion about the name.
case "$(err why unknownname)$(rc why unknownname)" in
*0) ;;
*) fail "why on an unknown name should still answer" ;;
esac

# --- 1: refused, for a reason ---------------------------------------------
# Every one of these must ALSO put something on stderr. A silent non-zero is
# the worst of both: the caller knows it failed and cannot say why.
for _case in \
	"kill nosuchsession" \
	"go unknownname" \
	"rename nosuch other" \
	"rename onlyone" \
	"theme sometheme" \
	"resume"
do
	# shellcheck disable=SC2086
	set -- $_case
	_got=$(rc "$@")
	is 1 "$_got" "mux $_case"
	_msg=$(err "$@")
	[ -n "$_msg" ] || fail "mux $_case exited 1 SILENTLY, with no reason"
	case $_msg in
	mux:*) ;;
	*) fail "mux $_case did not prefix its refusal: [$_msg]" ;;
	esac
done

# reload with no tmux.conf: the refusal path, reached only because
# XDG_CONFIG_HOME points into the scratch dir.
[ ! -f "$T/conf/tmux/tmux.conf" ] || fail "setup: tmux.conf should be absent"
is 1 "$(rc reload)" "mux reload with no tmux.conf"
case "$(err reload)" in
*"no tmux.conf"*) ;;
*) fail "reload's refusal did not name the missing file" ;;
esac

# --- 2: usage, or a verb this mux does not know --------------------------
# THE VERSION SIGNAL. A caller that gets 2 from `ssh host mux <verb>` learns
# that the remote mux is older than the verb, which is a different fact from
# "the command failed" and must not be conflated with it.
is 2 "$(rc nosuchverb)"       "an unknown verb"
is 2 "$(rc --nosuchflag)"     "an unknown option"
is 2 "$(rc agent-emit)"       "agent-emit with no state argument"
case "$(err nosuchverb)" in
*"unknown verb"*) ;;
*) fail "an unknown verb did not say so" ;;
esac

# --- and nothing else, ever ---------------------------------------------
# Sweep every verb the front end accepts, in the failure-prone empty context,
# and assert the code is one of the three. This is the assertion that keeps the
# ssh attribution sound: if any verb ever returns 3, or 255, a caller can no
# longer tell mux's answer from the transport's.
for _v in go resume kill reload ls hide show show-all save new help theme \
          rename edit why check views scan agent-list agent-summary \
          agent-doctor migrate-profiles
do
	_got=$(rc "$_v")
	case $_got in
	0|1|2) ;;
	*) fail "mux $_v returned $_got. Only 0, 1 and 2 are the contract, and
255/126/127 must stay attributable to the transport or the shell" ;;
	esac
done

# ... including with a junk argument, which is a different path through each.
for _v in go kill theme rename edit why hide show; do
	_got=$(rc "$_v" 'a name nothing knows')
	case $_got in
	0|1|2) ;;
	*) fail "mux $_v <junk> returned $_got, outside the 0/1/2 contract" ;;
	esac
done

pass
