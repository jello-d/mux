---
name: mux-agent
description: >-
  Coordinate with the other coding agents on this machine through mux - list
  them, see what state each is in, read what one is doing, wait for one to
  finish, and hand work to one. Use when you need to know what another agent
  is up to, block until one is done, or give one something to do.
---

# Working with peer agents through mux

You are running in a tmux session managed by `mux`. Other agents may be
working in other sessions on this machine. `mux agent` is how you see them and
coordinate with them.

Use it instead of driving tmux yourself. `tmux send-keys` and `capture-pane`
reach the same panes, and every safety rule below is one mux applies and tmux
does not.

## The answer is always JSON, even when it refuses

Every `mux agent` command prints exactly one JSON object on stdout. You never
have to decide whether today's answer is a document or a sentence. Each object
carries a `status`:

| `status` | exit | what it means |
| --- | --- | --- |
| `ok` | 0 | the answer follows |
| `refused` | 1 | a guard fired; `message` says which, and never guesses |
| `timed-out` | 1 | `wait` gave up; the object says what state it found |
| `usage` | 2 | the command was malformed |
| `no-such-name` | 3 | no session by that name here |

Switch on `status` when you want detail; the exit code is the same fact for a
shell. `mux` only ever exits 0, 1, 2 or 3, so 127 or 255 came from somewhere
else.

## Seeing who is here

```sh
mux agent peers
```

One object per session with a tracked agent:

```json
{"status":"ok","peers":[
  {"partition":"global","session":"api","state":"working","age":42,
   "control":"agent","root":"/home/you/src/api"}
]}
```

- `state` is `blocked`, `working` or `idle`. **`blocked` means it is waiting
  on a human** - a permission prompt, a question - not that it is stuck.
- `age` is SECONDS in that state, already computed. Never treat it as a
  timestamp; it is deliberately not one, so a reader on another machine never
  subtracts a remote clock from its own.
- `control` is who drives that pane: `human`, `agent`, `hybrid`, or `null`
  when mux could not determine it. See the rule below.
- `root` is where that session lives.

`mux agent status` is the same picture collapsed to one line per partition,
when you only want the worst state and a count.

Both are scoped to YOUR partition. `--partition NAME` asks about another one
and `--all` about every one; a partition is an isolation boundary, so do not
reach into one you were not pointed at.

## Reading what an agent is doing

```sh
mux agent read api            # what is on its screen now
mux agent read api -n 200     # plus 200 lines of scrollback
```

Returns `{"status":"ok","pane":"%4","text":"..."}`. The visible pane by
default, because an agent's scrollback can be enormous.

Do not remember the `pane` id to use later. mux resolves the right pane each
time it acts; a pane can die and be replaced, and a stale id points somewhere
real and wrong.

## Waiting for an agent

```sh
mux agent wait api idle -t 120
```

Blocks until `api` is `idle`, up to 120 seconds (default 300). This is the
verb that makes the others composable - do not poll `peers` in a loop.

On success: `{"status":"ok","waited":37}`. On timeout, status is `timed-out`
and the object tells you what it found instead:

```json
{"status":"timed-out","wanted":"idle","state":"blocked","waited":120,
 "message":"api is blocked, not idle, after 120s"}
```

That distinction matters. `state: working` means be more patient.
**`state: blocked` means a human is needed** - more waiting will not help, and
answering it yourself is the thing you must not do.

## Handing work to an agent

```sh
mux agent send api 'run the integration suite and report failures'
```

The text is pasted and submitted. `-` reads it from stdin, which is what to
use for anything long:

```sh
printf '%s' "$charge" | mux agent send api -
```

Sending to a `working` agent is fine: the text queues and it picks it up when
its turn ends. That is the normal way to give an agent its next instruction.

## The rule that matters

**Never answer another agent's permission prompt.**

A `blocked` agent is sitting at a prompt addressed to a *person*. If you type
into it, you have approved something on a human's behalf that they never saw.
That is not a mistake mux can undo for you.

So `mux agent send` refuses a `blocked` pane:

```json
{"status":"refused","reason":"blocked","override":"none","class":"human",
 "message":"api: it is human-controlled; mux does not answer a prompt on a
            human's behalf"}
```

What to do when you see that: **tell the human.** Say which session is
blocked, and what it is asking if you can see it with `mux agent read`. That
is the useful thing you can do, and it is usually what was wanted anyway.

### When an override exists

Some panes are agent-supervised - workers spawned by an orchestrator, with an
agent accountable for them rather than a person. An operator can permit those
to be answered, in a root-owned policy you cannot edit. When that is the case,
the refusal says so:

```json
{"status":"refused","reason":"blocked","override":"available",
 "message":"reviewer: the policy permits an override here; pass
            --answer-prompt"}
```

Only then may you retry with `--answer-prompt`. Two things are required and
neither is enough alone: the policy grants it, and you say explicitly that you
mean to. The flag is not permission - it is you acknowledging what you are
doing, and it is recorded.

`override: none` means there is no permission for this pane. Do not look for
another route to the same effect. `tmux send-keys` would work, and doing it
would be deliberately defeating a guard a human put there - and it leaves
mux's audit log, which is itself the signal that someone went around it.

`--blind` is the same arrangement for a pane whose state mux cannot classify.
Same rule: only when the refusal says an override is available.

### Why the guard is worded this way

mux runs as your user, so this is not a sandbox and it is not pretending to
be. It cannot stop you; it makes the dangerous thing not be the easy thing,
and it keeps the default somewhere you cannot quietly change. Treat it as a
statement of what the human wants, because that is exactly what it is.

## A common shape

Hand work to a peer, wait for it, read the result:

```sh
mux agent send builder 'add the retry test and run it'
mux agent wait builder idle -t 600 || echo "still not done"
mux agent read builder -n 100
```

If `wait` comes back `timed-out` with `state: blocked`, stop and report it.
