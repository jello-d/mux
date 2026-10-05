#!/bin/sh
# mux-agent-humming.t - `mux_agent_hum_scan`: which running processes count as
# work this pane's agent is still holding.
#
# THIS HALF SHIPPED DARK. The ranking, the glyph, the sidecar's liveness and
# the strip all had tests and corpus records; the DETECTION had neither, and
# it is the half that decides whether the state ever means anything. Same
# structural gap this package has recorded for both latch hooks, all four
# envhooks and the indicator's config key: the seam was proven and the shipped
# implementation of it had never once run.
#
# A FABRICATED /proc IS THE ONLY WAY TO ASSERT IT. The rule is a shape in the
# process tree, so the fixture has to BE a process tree: real processes cannot
# be arranged into the cases that matter (an orphan whose parent exited, a
# daemon in its own session) within a test, and `MUX_HUM_PROC` relocates the
# one directory the scan reads. Same seam as MUX_STYLE_PROC.
#
# THE RULE, which came from measuring Claude Code rather than from choosing:
# an agent reports a background task exactly while it HOLDS a handle to it,
# and that handle is visible as ancestry, because a tracked task keeps its
# tool shell alive as a child of the agent. So work is what sits UNDER the
# pane, and a service that re-parented to init is not under anything.
_name=mux-agent-humming
. "$(dirname "$0")/harness_lib"

. "$HERE/lib/mux-agent-state_lib"

# proc PID PPID [COMM] -> one fabricated process.
# The COMM default carries a SPACE and parentheses on purpose: /proc/PID/stat
# puts comm in parentheses and does not escape either, so the naive `$4` reads
# the wrong field. Measured on a real process named `we (ird) nam`: `$4`
# answered 1 (a fragment of the name) where the true ppid was this shell.
proc() {
  mkdir -p "$T/proc/$1"
  printf '%s (%s) S %s 0 0 0 -1 0 0 0 0 0 0 0 20 0 1 0 999 0 0\n' \
    "$1" "${3:-we (ird) nam}" "$2" >"$T/proc/$1/stat"
  printf 'Name:\tx\nPPid:\t%s\n' "$2" >"$T/proc/$1/status"
}

scan() { MUX_HUM_PROC="$T/proc" mux_agent_hum_scan "$1" "$2" | sort -n \
  | tr '\n' ' '; }
want() {   # <got> <want> <why>
  [ "$1" = "$2" ] || fail "$3
  got  [$1]
  want [$2]"
}

# The shape of a real agent pane, measured on this box and fabricated here:
#
#   900 pane shell
#   `-- 910 claude                 the agent
#       |-- 920 bash -c ...        a TRACKED task's tool shell, still alive
#       |   `-- 921 the job        the work itself
#       `-- 930 the emit hook      us: the scan runs from here
#           `-- 931 its own fork   the scan's cat/awk/subshell
#   1   init
#   `-- 940 a daemon the agent started days ago, re-parented, own session
proc 900 1 ; proc 910 900 claude ; proc 920 910 ; proc 921 920
proc 930 910 ; proc 931 930 ; proc 940 1

# THE EXCLUSIONS COME FIRST, AND THAT ORDER IS DELIBERATE. The exact-equality
# assertion at the end covers every one of them, so put it first and every
# mutation dies on it: measured, five different broken rules all reported the
# same failure, which says a line is load-bearing and nothing about WHICH
# rule it carries. Ordered this way each mutation lands on the assertion that
# names it, which is the difference between the corpus proving a guard and the
# corpus proving a file.

# --- NEITHER THE AGENT NOR THE PANE'S SHELL IS WORK ------------------------
# Both sit on the scanner's own chain UP. Without that the agent is reported
# as the work it is holding, and every agent pane in the fleet reads humming
# for ever, which is the loudest possible version of this bug.
case $(scan 900 930) in
*910*) fail "the AGENT is reported as work it is holding, so every pane with
an agent in it would hum for ever" ;;
esac
case $(scan 900 930) in
*900*) fail "the pane's own shell is reported as work" ;;
esac

# --- NOR THE SCAN'S OWN MACHINERY ------------------------------------------
# The chain DOWN, and this one is not symmetry: it is a live defect the first
# version shipped. It re-read each candidate's ancestry from /proc, and the
# scan's own forks (the `cat`, the awk, the substitution subshell) are alive
# when the snapshot is taken and GONE microseconds later, so the second read
# answered nothing, the process could not be attributed, and it was reported
# AS WORK. Reproducible: three phantom pids per run against a real /proc.
# Every question is asked of the one snapshot now, which cannot race itself.
case $(scan 900 930) in
*931*) fail "a process the scan itself forked is reported as work: the
self-match trap, which here makes a session hum about the check that was
asking whether it hums" ;;
esac

# --- AND A RE-PARENTED SERVICE IS NOT WORK ---------------------------------
# THE LIVE DEFECT, and the reason this file exists. The previous rule keyed on
# `TMUX`/`TMUX_PANE` in the environment, which every process that ever passed
# through the pane carries for ever, so a watcher an agent started days ago
# read as work. Measured on a real session: `humming` for 44 HOURS over three
# live processes with ppid 1, while the agent itself reported nothing running.
# Asserted as an ABSENCE from the answer above, because the failure was a
# report that was factually true about the processes and wrong about the
# question.
case $(scan 900 930) in
*940*) fail "a process that re-parented to init is reported as work. Nothing
holds it: the agent has no handle on it, cannot wait for it and reports
nothing, so mux claiming the session is still busy is unbounded in time,
because nothing will ever clear it." ;;
esac

# --- AND WHAT IS LEFT IS EXACTLY THE WORK ----------------------------------
# The summarising assertion, deliberately AFTER the exclusions: it is an
# equality, so it subsumes all three, and first it would be the only thing any
# mutation ever reported. It earns its place by proving the positive half too,
# that work IS found rather than the scan simply answering nothing.
want "$(scan 900 930)" "920 921 " "the tracked task and its tool shell are the
work: they are alive and still under the pane, which is exactly what makes the
agent able to report them too"

# --- THE PERSPECTIVE IS AN ARGUMENT, AND IT CHANGES THE ANSWER -------------
# `excluding the caller` only means something relative to a position in the
# tree. Asked from the OTHER tracked task's shell, that task is now the
# caller's own machinery and the hook is the work. Asserted because reading
# `$$` instead made the answer depend on which pane the shell was in, which is
# how the first probe of this reported a neighbouring pane's agent as work.
want "$(scan 900 920)" "930 931 " "the answer must be relative to the SELF it
was given, or the exclusions describe the wrong process"

# --- A PANE WITH AN AGENT AND NOTHING ELSE IS NOT HUMMING ------------------
# The control, and the common case by far: every quiescent agent pane measured
# on this box had exactly one descendant, the agent itself. A rule that cannot
# answer "nothing" here would paint the whole fleet green-with-a-gear.
proc 800 1 ; proc 810 800 claude ; proc 820 810
want "$(scan 800 820)" "" "a pane holding only its agent and the scanner has
no background work, and this is the state nearly every pane is in"

# --- A DEEPER TREE IS STILL REACHED ---------------------------------------
# A real job is several levels down (tool shell, then a wrapper, then the
# program), so a walk that stopped at the agent's direct children would see
# the shell and miss what it is actually running. The 44-hour watcher was
# itself `sh -c` plus two python processes.
proc 700 1 ; proc 710 700 claude ; proc 720 710 ; proc 721 720
proc 722 721 ; proc 723 722 ; proc 730 710
want "$(scan 700 730)" "720 721 722 723 " "the walk must reach the whole
subtree: the program doing the work is several levels below the tool shell"

# --- IT REFUSES RATHER THAN GUESSING --------------------------------------
# Both arguments are structural. With no root there is nothing to walk from,
# and with no self every exclusion is wrong, so the honest answer is silence:
# no sidecar is written and the state stays `idle`, which under-reports rather
# than claiming an activity that was never confirmed.
want "$(scan '' 930)" "" "with no root to walk from, the scan must answer
nothing rather than searching the whole table"
want "$(scan 900 '')" "" "with no perspective, every exclusion names the wrong
process, so the scan must answer nothing rather than report the agent"
want "$(MUX_HUM_PROC=$T/nosuch mux_agent_hum_scan 900 930)" "" "with no /proc
the detection half cannot run at all, and it must degrade to silence: this is
what makes the feature safe on a platform that has none"

pass
