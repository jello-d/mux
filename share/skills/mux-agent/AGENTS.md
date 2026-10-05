# Working with peer agents through mux

This applies when you are working inside a tmux session managed by `mux`. If
`mux` is not on PATH, or `$TMUX` is unset, none of it does. `mux agent peers`
is the quickest check: if it answers JSON, you are in one.

Other agents may be working in other sessions on this machine. `mux agent` is
how you see them and coordinate with them.

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

One object per WINDOW with a tracked agent. A session usually has one, and
then this reads exactly as a per-session answer; a session being supervised
has one window per worker, and each answers for itself:

```json
{"status":"ok","peers":[
  {"partition":"global","session":"api","window":0,"window_id":"@4",
   "window_name":"build-1","state":"working","age":42,"control":"agent",
   "root":"/home/you/src/api"}
]}
```

- `window_id` IS THE HANDLE. Pass it to `--window` on `read`, `send` and
  `class`. A tmux window id is never reused, so a stale one names nothing
  rather than whatever took its place.
- `window` is the tmux window INDEX, and it is for DISPLAY ONLY. An index is
  a recyclable slot: kill the window at index 2 and the next one created
  takes it, so acting on a remembered index types into a different worker and
  reports success. Never pass it to `--window`.
- `window_name` is what the window is called, and `--window` takes it too.
  It is the convenient form and the id is the precise one: mux acts on a name
  only while it is UNIQUE in that session, and refuses with the candidate ids
  listed when it is not. Nothing stops two windows sharing a name, so if you
  chose the name and need certainty, use the id.
- `window_id` and `window_name` are `null` when mux could not reach that
  server, for the same reason `control` is: unknowable, never defaulted.
- `state` is `blocked`, `working`, `humming` or `idle`. **`humming` means the
  turn ENDED but work it started is still running** (a build, a test run, a
  server): you may talk to it, and "done" would be the wrong word. It ranks
  between `working` and `idle`, and it clears itself the moment the last job
  exits. **`blocked` means it is waiting
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
mux agent read api                     # what is on its screen now
mux agent read api -n 200              # plus 200 lines of scrollback
mux agent read api --window @7 -n 50   # one worker in a supervised session
```

Returns `{"status":"ok","window":"@7","pane":"%4","text":"..."}`. The visible
pane by default, because an agent's scrollback can be enormous.

Do not remember the `pane` id to use later. mux resolves the right pane each
time it acts; a pane can die and be replaced, and a stale id points somewhere
real and wrong. A `window_id` is different and IS worth keeping: tmux never
reuses one, so it either names the window you meant or names nothing.

WITH SEVERAL AGENT WINDOWS, `--window` IS REQUIRED. The bare form refuses
rather than reading whichever worker ranks worst, and the refusal lists the
ids to choose from.

## Watching for changes instead of asking repeatedly

```sh
mux agent stream              # one JSON object per line, forever
mux agent stream --any -i 1   # every partition, checked every second
```

Prints the same object `mux agent status` does, **one per line**, and only
when something CHANGES. The first line is the current state, so you are never
blank waiting for the first event.

- **Prefer this to a poll loop.** Asking repeatedly costs a process per ask;
  a stream costs one and tells you sooner.
- **A heartbeat line** (`{"status":"ok","heartbeat":true}`) arrives during
  quiet periods, so you can tell a calm machine from a dead connection. If
  heartbeats stop, treat the source as UNKNOWN, never as calm.
- **It exits when you stop reading**, so closing the pipe is how you stop it.
  Over a transport that means a dropped connection cleans up the far side.

## Waiting for an agent

```sh
mux agent wait api idle -t 120
```

Blocks until `api` is `idle`, up to 120 seconds (default 300).

**`wait ... idle` is satisfied by `humming` too**, because both mean the turn
is over, and the answer tells you which one you got. Wait for `humming`
explicitly only if you specifically care that background work is still going.
`wait ... working` stays exact: it means "wait for a turn to START", so a
session that has already finished one does not satisfy it. This is the
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

`--window` picks one worker, by id or by name, and is required once the
session holds more than one:

```sh
mux agent send api --window @7 'rerun just the failing case'
```

THE GATE JUDGES THE PANE YOU NAMED, not the session. One worker sitting at a
permission prompt does not make its idle siblings unwritable, and an idle
session does not let a charge through to a `blocked` worker.

Sending to a `working` agent is fine: the text queues and it picks it up when
its turn ends. That is the normal way to give an agent its next instruction.

## Opening a window for a worker

```sh
mux agent open api --name build-1 --dir ~/src/api \
  --cmd 'make watch' --control agent --attention agent
```

Opens a WINDOW in a session that already exists, and declares what it is for.
It answers with the window it made:

```json
{"status":"ok","partition":"global","session":"api","window":3,
 "window_id":"@7","control":"agent","attention":"agent"}
```

- KEEP `window_id`. It is the handle for every later call about this worker,
  and it is why the create answers it: an index alone would send you back
  through `peers` to learn what the create already knew.

- It never creates a session. That is a different job, and if `api` is not
  there you get `no-such-name` rather than a surprise session.
- It is always DETACHED. Your window does not move the human's view, which
  would be an interrupt nobody asked for.
- `--control` says who may TYPE into the new pane: `agent` is what makes it
  reachable by `mux agent send` where a policy allows it, and the default
  without the flag is `human`, which is refused to every sender.
- `--attention` says whose attention it is OWED. `agent` keeps it off the
  human's status strip, their notifications and their `next-blocked`, which
  is what stops one worker waiting on you from painting a whole session
  blocked. Leave it off and the human sees the worker as their own.
- You may declare either class on a window you are CREATING. There is no verb
  that reclassifies a pane somebody else made.
- A partition is a boundary: opening a window in another one is refused
  outright, with no flag and no policy that opens it. Opening runs a COMMAND,
  so it crosses harder than sending text does.

## Escalating a worker to the human

```sh
mux agent class api --window @7 --attention human
```

Changes a LIVE pane's class, which is how an escalation works: you could not
resolve something, so the human has to see it, and that must take effect
without restarting the agent.

- **You may always move a pane TOWARD the human** (`agent` -> `hybrid` ->
  `human`), on either marker. That direction only ever removes your own
  permission and adds their sight of the pane, so it is always allowed.
- **You may not move it away from the human.** Relaxing a pane back to
  `agent` grants something, and it is refused with `reason: relax` unless a
  HUMAN is at a terminal and passes `--yes`. Do not try to work around that;
  tell the human what you need instead.
- The two markers are judged separately, which is the point of their being
  two: escalate `--attention` and keep `--control agent`, and the human sees
  the worker while you can still type into it.
- `--window` NAMES THE WORKER, by `window_id` (`@7`) or by window name. It
  is not optional where there is more than one: with several agent windows in
  the session the bare form REFUSES, naming the candidate ids, rather than
  acting on the session's worst agent. That refusal is deliberate. Guessing
  would escalate somebody else's worker and report success.
- Every change is logged, including yours.

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

### One refusal has no override at all

A partition is a boundary between worlds, and on some machines it is enforced
by the kernel rather than by convention: the panes on the other side hold
privileges yours was refused. So `mux agent send` never types across one, and
unlike the case above there is no flag and no policy line that opens it:

```json
{"status":"refused","reason":"cross-partition","override":"none",
 "message":"wsess: it is in partition work and this call is from
            personal; mux does not type across a partition boundary"}
```

You will also see it when mux cannot tell which partition *you* are in. That
is deliberate: guessing would mean guessing which side of a boundary a command
lands on.

Reading across a partition is fine and supported (`peers --partition NAME`).
It is only typing that stops.

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
