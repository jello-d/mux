"""The supervisor: which items should exist, and what each one should show.

PLATFORM-FREE, AND THAT IS A TESTED PROPERTY rather than an aspiration. One
tray item per (host, partition), updated live: on a state/count change the
owned pixmap is re-rendered and the presenter is told to repaint. State comes
from each host's `mux agent stream`, with a poll as the downgrade path, and a
manual override file takes precedence when present for testing without live
sessions.

THE PRESENTER IS BEHIND `_backend()` and is the only platform-specific thing
in the package: it owes `session_bus()`, `toaster(bus, enabled)` and
`export(index, tile, activate) -> handle`. `backend_dbus` is the
StatusNotifierItem one; a macOS presenter is a sibling of that file and
touches nothing here. The split was measured, not assumed: with dbus_next
absent, 147 of this package's 289 tests used to error, because the only way to
reach any decision was to construct a `ServiceInterface` subclass.

SOME SNI VOCABULARY STAYS HERE ON PURPOSE: `item_bus_name`, `item_id`,
`wants_reregister` and the watcher paths are pure string knowledge about a
naming convention, with no import behind them, so keeping them on this side is
what lets their rules be asserted where there is no bus. A presenter that
cannot use them simply does not.

EACH HOST STREAMS INDEPENDENTLY. One feed per host rather than a gather, so a
box that is slow to answer delays only its own icon. A shared round would make
every host as slow as the worst one, which over ssh is the normal case.
"""
import asyncio
import json
import os
import shlex
# SIGKILL by NAME, which this file no longer strictly needs and keeps anyway:
# the hazard was that `dbus_next.service` exports a `signal` DECORATOR, so a
# module-level `import signal` beside it made `signal.SIGKILL` raise
# AttributeError on the TIMEOUT path only, i.e. for the first time at the exact
# moment a host became unreachable. The decorator left with the presenter, so
# the collision now lives in backend_dbus.py; importing the constant by name is
# immune either way and costs nothing.
from signal import SIGKILL

from .render import MARK_PALETTE, host_mark, icon_pixmap, parse_pair
from .slots import Slots
from . import sources
from .sources import (activate_cmd, activate_hook, hook_path,
                      load as load_sources, streams as load_streams,
                      local_label, remote_argv, toast_hook, valid_partition)

WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
# State feed. MUX runs `mux agent-summary` ("<state> <count>") as the live
# source, polled every POLL seconds. CTL is an OPT-IN manual override file for
# testing: set MUX_DESKTOP_NOTIFIER_CTL to a path and write "<state> <count>"
# into it to force a value. UNSET by default, so the deployed service reads ONLY
# the live feed and no stray /tmp file can silently pin it.
MUX = os.environ.get("MUX_BIN", "mux")
# 5s, not the 1.5s of the single-local-host days: a source may be an ssh round
# trip now, and polling a remote box thrice a second is rude for a signal that
# changes on human timescales.
POLL = float(os.environ.get("MUX_DESKTOP_NOTIFIER_POLL", "5"))
# A SOURCE THAT HANGS MUST STILL ANSWER. ssh into a blackholed host does not
# fail, it SLEEPS, so without a deadline that item would freeze on its last
# value forever, showing a calm icon for a machine that fell off the network.
# That is the precise failure this indicator exists to prevent, so the timeout
# is not a nicety; it is what makes `unknown` reachable.
TIMEOUT = float(os.environ.get("MUX_DESKTOP_NOTIFIER_TIMEOUT", "10"))
CTL = os.environ.get("MUX_DESKTOP_NOTIFIER_CTL")
# How often to re-read latch's lock directory. Slower than POLL on purpose: this
# is a listdir of a tmpfs, but a host appearing a few seconds after you latch is
# imperceptible, while an item flickering in and out is not.
DISCOVER = float(os.environ.get("MUX_DESKTOP_NOTIFIER_DISCOVER", "5"))
# THE TWO SURFACES, EACH SWITCHABLE, BOTH ON. This daemon is the only thing
# that draws mux on a desktop, so turning one off has to be possible without
# losing the other: a bar with its own agent widget wants the toasts and not
# the icon, and somebody who finds banners rude wants the icon and not the
# toasts. OFF means INERT rather than absent, so nothing downstream has to
# know which surfaces exist.
TRAY = os.environ.get("MUX_DESKTOP_NOTIFIER_TRAY", "1") != "0"
TOASTS = os.environ.get("MUX_DESKTOP_NOTIFIER_TOASTS", "1") != "0"
# Partitions to say nothing about, on EITHER surface. Resolved in sources.py
# beside the other seams; `mux.demo` by default, see DEFAULT_IGNORE there.
IGNORE = sources.ignored()
# A STREAM THAT STOPS SPEAKING IS NOT A CALM HOST. This is the one thing
# polling gave away for free: there a non-zero exit could only be the
# transport, so `unknown` was trustworthy. A stream has no such signal, which
# is why `mux agent stream` sends a heartbeat during quiet periods and why
# this number exists to notice its absence.
#
# IT MUST EXCEED THE PRODUCER'S HEARTBEAT, and that is a CROSS-PROCESS
# contract: the stream's default is 15s, so anything at or below it declares a
# perfectly healthy feed dead. Three missed beats is the margin, which also
# survives a loaded box without flapping.
STALE = float(os.environ.get("MUX_DESKTOP_NOTIFIER_STALE", "45"))
# A dead stream is retried, with a ceiling: a host that is simply gone must
# not be hammered, and the first retry must still be quick because the usual
# cause is a restart rather than an outage.
RESPAWN = float(os.environ.get("MUX_DESKTOP_NOTIFIER_RESPAWN", "2"))
RESPAWN_MAX = float(os.environ.get("MUX_DESKTOP_NOTIFIER_RESPAWN_MAX", "30"))
# On a state/count change the `_` cursor blinks BLINK_N times at BLINK_MS each,
# to catch the eye, then settles cursor-on.
BLINK_N = int(os.environ.get("MUX_DESKTOP_NOTIFIER_BLINK", "5"))
BLINK_MS = int(os.environ.get("MUX_DESKTOP_NOTIFIER_BLINK_MS", "250"))


class Tile:
    """WHAT ONE TRAY ITEM BELIEVES, with no transport under it.

    Everything here answers "what should this item show": the state, the
    count, the host identity, the overlay, the blink schedule and the words a
    tooltip uses. None of it knows what a bus is, which is the point: a
    platform backend wraps one of these and publishes it, so a second platform
    is an ADDITION rather than a fork of the decisions.

    IT WAS MEASURED, NOT ASSUMED. With dbus_next absent, 147 of this package's
    289 tests errored, because the only way to reach any of this was to
    construct a `ServiceInterface` subclass. The 80%-shared figure in the
    sizing note was about LINES; the tests told a worse story, and they are
    what says whether a Mac can run the shared half.

    THE TWO CALLBACKS ARE THE WHOLE SEAM. A repaint has to reach the tray host
    somehow, and `on_icon`/`on_status` are how, set by whichever backend
    exports this tile. They default to doing nothing so a bare Tile is
    constructible and assertable, which is what makes the decisions testable
    on a platform that has no tray at all.
    """

    def __init__(self, state="none", count=None, label=None, host=None,
                 local=False, part=None):
        # Set by the backend that exports this tile; no-ops until then.
        self.on_icon = lambda: None
        self.on_status = lambda _status: None
        # The label names the host this item speaks for. None keeps the old
        # unlabelled identity, which is what the existing tests construct.
        self._label = label
        # The (fg, bg) identity pair, or None for the host-neutral look. Fixed
        # for this item's life: it derives from the NAME by hashing, so it
        # cannot change while the daemon runs, and re-querying it per poll would
        # be a subprocess per host per tick for an answer that never moves.
        self._host = host
        # Whether this item speaks for THIS box. Fixed for the item's life (
        # a host does not stop being local), and needed at construction
        # because Id is read the moment a tray host sees the item.
        self._local = local
        # The three-character host mark, or None for the single-host look.
        # Set later too: it appears when a second host joins the tray and goes
        # again when you detach, so one item never carries a label it does not
        # need.
        self._mark = None
        # The palette slot the mark wears, or None for the LOCAL host. Carried
        # beside the mark because the two turn on together and neither means
        # anything without the other.
        self._ink = None
        # The A-Z letter naming this item's PARTITION, or None when the host
        # has only one. Set later for the same reason the mark is: a second
        # partition can appear while the daemon runs.
        self._part = part
        self._state = state
        self._count = count
        self._pixmap = icon_pixmap(state, count, host=host, part=part)
        self._blink = None

    def status(self):
        return "NeedsAttention" if self._state == "blocked" else "Active"

    # --- what a presenter asks for, all of it platform-free ---------------
    @property
    def label(self):
        return self._label

    @property
    def pixmap(self):
        return self._pixmap

    def ident(self):
        return item_id(self._label, self._local)

    def title(self):
        return f"mux @ {self._label}" if self._label else "mux"

    def tooltip(self):
        # The TITLE carries the host, because with several items in a tray
        # "mux" alone identifies nothing: the one thing you want on hover is
        # WHICH machine this is.
        if self._state == "unknown":
            body = "cannot reach this host"
        elif self._count is None:
            body = "all sessions idle"
        else:
            body = f"{self._count} session(s): {self._state}"
        return self.title(), body

    def _paint(self, cursor=True):
        self._pixmap = icon_pixmap(self._state, self._count, cursor=cursor,
                                   host=self._host, mark=self._mark,
                                   ink=self._ink, part=self._part)
        self.on_icon()

    def set_mark(self, mark, ink=None, part=None):
        """Show or hide the overlay: the host mark, its palette slot, and the
        partition letter. Repaints only on a real change, so the discovery
        loop can call this every tick without churning the tray.

        ALL THREE fields decide that. Comparing only the mark would pin a host
        to the first colour it was ever drawn with, and a reshuffle would then
        be invisible until something else forced a repaint.

        THE LETTER TRAVELS WITH THE MARK because one pass computes both and
        both answer "which tile is this": the mark says which machine, the
        letter which partition of it. Two setters would mean two repaints on
        the tick where a host gains a second partition, which is exactly the
        tick where both change."""
        if mark == self._mark and ink == self._ink and part == self._part:
            return
        self._mark, self._ink, self._part = mark, ink, part
        self._paint()

    def set(self, state, count):
        """Update the icon live: re-render, tell the host to repaint, then blink
        the cursor a few frames to catch the eye."""
        self._state, self._count = state, count
        self._paint()
        self.on_status(self.status())
        if self._blink is not None:
            self._blink.cancel()
        self._blink = asyncio.ensure_future(self._do_blink())

    async def _do_blink(self):
        """Toggle the `_` cursor BLINK_N times, then settle cursor-on. Cancelled
        by the next set(); always leaves the cursor showing."""
        try:
            for _ in range(BLINK_N):
                self._paint(cursor=False)
                await asyncio.sleep(BLINK_MS / 1000)
                self._paint(cursor=True)
                await asyncio.sleep(BLINK_MS / 1000)
        except asyncio.CancelledError:
            self._paint(cursor=True)
            raise


def _parse(text):
    """'<state> <count>' -> (state, count). idle/none carry no number (the
    badge is a check / absent), so their count normalises to None; a missing or
    non-numeric count is None too. Returns None on empty input."""
    parts = text.split()
    if not parts:
        return None
    state = parts[0]
    if state in ("idle", "none"):
        return (state, None)
    raw = parts[1] if len(parts) > 1 else "-"
    if raw in ("-", "check"):
        return (state, None)
    try:
        return (state, int(raw))
    except ValueError:
        return (state, None)



# `global` is the reserved baseline partition, and mux's own `mux resume`
# grammar already treats it that way. Kept here rather than imported because
# it is a NAME mux publishes, not a rule this presenter gets to decide.
BASELINE = "global"


def parse_all(text):
    """`mux agent status` -> {partition: (state, count)}, or None.

    THE MACHINE CONTRACT, not the human one. It answers for every partition in
    ONE round trip (a reader on another box cannot know the partition names
    to ask for, and over a transport N partitions must not mean N connections),
    and it answers as JSON, so this reader gets types and structure instead
    of a field order it has to agree about out of band. The count arrives as a
    number rather than as a string that has to be re-parsed, and the escaping
    of a session name or a partition is mux's problem rather than a delimiter
    convention both sides have to keep in step.

    NONE MEANS DO NOT TRUST THIS ANSWER, which is a distinction the
    tab-separated form could not make: a document that does not parse, or one
    whose `status` is not `ok`, is a host that said something other than an
    answer. That is `unknown` territory, not an empty one: the caller must
    not read it as "this host has no partitions".

    A ROW IS STILL DROPPED if its partition is not a DNS label: these names
    arrive from another machine and go straight back out inside a shell
    command, so this remains untrusted input crossing into `sh -lc`, whatever
    the transport encoding.

    A row whose STATE is a word mux would never emit becomes `unknown` rather
    than being dropped: the partition is real, and the feed answering junk
    about it is exactly what `unknown` is for. Dropping it would make the item
    disappear, which reads as "that partition is gone".
    """
    try:
        doc = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(doc, dict) or doc.get("status") != "ok":
        return None
    rows = doc.get("partitions")
    if not isinstance(rows, list):
        return None
    out = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = row.get("partition")
        state = row.get("state")
        count = row.get("count")
        if not isinstance(name, str) or not valid_partition(name):
            continue
        if not isinstance(state, str):
            continue
        if not isinstance(count, int) or isinstance(count, bool):
            count = None
        out[name] = (state, count) if state in KNOWN else UNKNOWN
        if state in ("idle", "none"):
            out[name] = (state, None)
    return out


def partition_letters(parts):
    """-> {partition: letter}, or {} when there is only one.

    A IS THE BASELINE. `global` always sorts first and always gets A;
    everything else follows alphabetically. Stable ordering across restarts
    was explicitly not required (the user's call), and alphabetical is chosen
    BECAUSE it needs no state: nothing is remembered, so nothing can drift
    between two machines drawing the same fleet, which is the failure the
    per-host colour file already has to work around.

    ONE PARTITION GETS NO LETTER, the same rule as the host mark one level up:
    a letter distinguishing a thing from nothing is noise, and a host with one
    partition must keep the icon it has always had, byte for byte.

    PAST Z THERE IS NO LETTER rather than a second alphabet. Partitions are
    meant to be rare and few; 27 of them is a different problem, and a tray
    that starts drawing `AA` would be making it look solved.
    """
    if len(parts) < 2:
        return {}
    ordered = sorted(parts, key=lambda p: (p != BASELINE, p))
    return {p: chr(ord("A") + i) for i, p in enumerate(ordered[:26])}


def item_key(host, part, solo):
    """The identity of one tray item: `host`, or `host:partition`.

    THE SOLO FORM IS THE OLD ONE, unchanged, which is what keeps a
    single-partition host publishing exactly the item it always did: same
    Id, same tooltip, same everything. The colon grammar matches `mux latch`'s
    own target, so the two read the same way.
    """
    return host if solo else f"{host}:{part}"


def host_of(key):
    """The host half of an item key. Everything before the FIRST colon, the
    same rule latch's target grammar uses."""
    return key.split(":", 1)[0] if key else key


def part_of(key):
    """The partition half of an item key, or None for the solo form."""
    if not key or ":" not in key:
        return None
    return key.split(":", 1)[1]


def _read_override():
    """The opt-in override file (MUX_DESKTOP_NOTIFIER_CTL) if set and
    parseable, else
    None, so with the env unset the live feed is the only source."""
    if not CTL:
        return None
    try:
        # `with` rather than `open(CTL).read()`. On CPython the bare form is
        # not a leak, refcounting closes the handle the moment .read()
        # returns, so the ResourceWarning the test run surfaced was about
        # DEPENDING on that, not about descriptors piling up. Worth fixing
        # anyway, since this runs on every poll and the guarantee is an
        # implementation detail rather than a language one, but it was never
        # the fd-exhaustion bug it first looked like.
        with open(CTL) as fh:
            return _parse(fh.read())
    except OSError:
        return None


UNKNOWN = ("unknown", None)
# The states `mux agent-summary` can emit. A feed answering ANYTHING else has
# not told us about that host, so it is UNKNOWN rather than whatever the
# renderer happens to fall back to.
#
# NOT PARANOIA: measured. A mis-quoted ssh source ran the bare session PICKER
# on the far side (ssh concatenates its args and the remote shell re-splits, so
# `sh -lc` `mux agent-summary` became `sh -lc mux` with `agent-summary` as $0).
# Its output parsed to the state `1)`, which the renderer draws with the `none`
# fallback: a calm grey tile for a host whose feed is misconfigured. It happened
# to exit non-zero and so read as unknown anyway, but that was luck. A feed that
# returns plausible garbage and exits 0 is the failure this closes.
# `humming` joined in the release that added it (agent contract 5). THE SKEW
# DIRECTION IS WORTH KNOWING: an OLD indicator against a NEW mux sees a word
# it does not know and draws `unknown`, i.e. slate blue, which claims the host
# is unreachable when it is perfectly fine. That is the three-copy problem this
# package already names (package / installed / running), and the existing
# mitigation is the notice core's install prints when the indicator does not
# match. Nothing here can fix it from this side; it is recorded so the symptom
# is recognised rather than diagnosed.
KNOWN = ("blocked", "working", "humming", "idle", "none")


async def _query(argv):
    """Run one source -> (state, count). NEVER None.

    THE EXIT CODE IS THE WHOLE POINT, and ignoring it was the bug this replaces.
    `mux agent-summary` prints `none 0` and exits 0 on a host with no agents, so
    EMPTY IS EXIT 0 and a quiet host is a real answer. A non-zero exit therefore
    has no meaning of its own (it can only be the transport), so it must
    draw as UNKNOWN, never as calm.

    The old version read stdout and ignored the status: a failed ssh gave empty
    output, which parsed to None, which the caller treated as "no change" and
    left the previous icon up. So an unreachable machine kept showing whatever
    it last said, indefinitely. A tray confidently reporting a host it cannot
    see is worse than no tray, and it is the exact thing this feature exists to
    prevent.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            # A SESSION OF ITS OWN, so a timeout can kill the whole GROUP.
            # Measured: killing just the direct child leaves a grandchild
            # holding the stdout pipe, and `proc.wait()` then blocks until that
            # grandchild exits: 30s against a `sh -c "sleep 30"` source, with
            # the timeout itself firing correctly at 0.3s. That stalls this
            # host's poll loop for the grandchild's whole life, which is the
            # very freeze the timeout exists to prevent, reintroduced through
            # the reaping path. A source is an arbitrary command, so a
            # wrapper that spawns a child is not an edge case.
            #
            # AND IT IS WHAT MAKES THE killpg BELOW SAFE, which is the half
            # that was never written down. Without a session of its own the
            # child inherits OUR process group, so `killpg(getpgid(child))`
            # resolves to the DAEMON'S group and SIGKILLs the indicator
            # itself. Measured, 2026-09-26: deleting this argument turns a
            # source timeout into suicide, and it would fire for the first
            # time at the exact moment a host became unreachable.
            #
            # These two lines are a PAIR. Neither may be "simplified" without
            # the other, and the failure mode is not a stall but a daemon that
            # vanishes whenever the network does.
            start_new_session=True)
    except OSError:
        return UNKNOWN
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except asyncio.TimeoutError:
        await _reap(proc)
        return UNKNOWN
    if proc.returncode != 0:          # the transport failed, not the host
        return UNKNOWN
    got = _parse(out.decode("utf-8", "replace"))
    # _parse stays a pure text->tuple function and passes any word through;
    # deciding whether to TRUST it belongs here, with the exit code.
    if got is None or got[0] not in KNOWN:
        return UNKNOWN
    return got


async def _query_all(argv):
    """Run one source -> {partition: (state, count)}, or None.

    NONE MEANS COULD NOT ASK, and it is a different answer from an empty dict.
    A host that answered with no partitions is quiet; a host that could not be
    reached is UNKNOWN, and every item it owns must say so. Collapsing the two
    is the original sin this feature keeps having to avoid: it is what left
    an unreachable box showing whatever it last said, forever.

    Shares `_query`'s subprocess rules by calling it? No: it needs the whole
    stdout rather than one parsed line, and _query's value is the exit-code
    discipline, which is repeated here rather than abstracted because the two
    differ in exactly one line and a wrapper would hide which.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            # The PAIR: see _query. Neither line may be simplified without
            # the other, and the failure mode is a daemon that vanishes
            # whenever the network does.
            start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except asyncio.TimeoutError:
        await _reap(proc)
        return None
    if proc.returncode != 0:      # the transport failed, not the host
        return None
    return parse_all(out.decode("utf-8", "replace"))


class Toaster:
    """Raises and withdraws desktop notifications. The ONLY thing that does.

    WHY IT MOVED HERE AT ALL. `mux-agent-state-emit` used to raise the banner
    itself, on the box the AGENT runs on, which is the one machine that may
    well have nobody sitting at it: every blocked latched session has been
    popping a toast on a remote desktop for as long as latch has existed.
    Structural, not a bug in the notification path, and unfixable there: a
    hook cannot reach the box the human is at. A stream can.

    THE DECISION IS STILL THE WATCHED BOX'S. All of "is this the pane you are
    looking at", `@mux-notify-always` and `@mux-attention` are properties of a
    pane over there at the moment it changed, so the stream applies them and
    sends a verdict. This class owns WORDING and LIFETIME and nothing else.

    OVER THE SESSION BUS, not through `notify-send`, and the reason is the id.
    A banner has to be withdrawn when the thing it announced stops being true,
    which needs the id back; `notify-send -p` gives one, and closing it then
    needs a second backend chosen from whatever happens to be installed, which
    is a problem this daemon does not have. It is already a bus client with a
    connection in hand, and `notify-send` is itself only a bus client.
    """

    IFACE = "org.freedesktop.Notifications"
    PATH = "/org/freedesktop/Notifications"

    def __init__(self, bus, enabled=True, app="mux"):
        self._bus = bus
        self._enabled = enabled
        self._app = app
        self._iface = None
        # (host, partition, session) -> (id, kind). The kind is kept because
        # it decides when the banner stops being true: a `blocked` one goes
        # when the pane is no longer blocked, a `finished` one when the turn
        # starts again. Without it there is no rule, only a timer.
        self._ids = {}

    async def _notifications(self):
        if self._iface is None:
            intro = await self._bus.introspect(self.IFACE, self.PATH)
            obj = self._bus.get_proxy_object(self.IFACE, self.PATH, intro)
            self._iface = obj.get_interface(self.IFACE)
        return self._iface

    def text(self, host, session, kind, local):
        """The banner, and the HOST rides in the TITLE beside the session.

        emit could never say which machine, because it only ever ran on one.
        A daemon watching several can, and without it two boxes running the
        same session name produce identical banners: the tray spent two
        releases learning that lesson about colour.

        THE TITLE, NOT THE BODY, and not the app name either. Which field a
        reader actually SEES is the notification daemon's choice, and the one
        in use here renders only the summary and the body:

            format=<big><b>%s</b></big>\n<span foreground="#fff">%b</span>

        So `%a` is never drawn, and putting the host in the app name would
        have made it INVISIBLE while also splitting `group-by=app-name` into
        one group per machine. WHICH MACHINE belongs with WHICH SESSION,
        because together they are the address of the thing asking for you;
        the body says what it wants, which is the same sentence on every box.
        """
        if kind == "blocked":
            summary = f"Claude needs you: {session}"
            body = "permission or input"
        else:
            summary = f"Claude finished: {session}"
            body = "your turn"
        if not local and host:
            summary = f"{summary} (on {host})"
        return summary, body

    async def compose(self, host, part, session, kind, local):
        """The banner, from the hook if one is configured, else built in.

        FALLS BACK RATHER THAN FAILING, on every error there is: no hook, a
        hook that will not start, one that exits non-zero, one that hangs,
        one that prints nothing. A styling preference must never cost
        somebody the notification itself, which is the whole signal.

        ONE STREAM, SPLIT ONCE: the first line is the summary and everything
        after it is the body. That is what lets a hook decide where the line
        break goes, which is the entire point for a daemon format that joins
        summary and body on one row; a two-field protocol would have put that
        decision back here, where the daemon's layout is not known.
        """
        hook = toast_hook()
        if not hook:
            return self.text(host, session, kind, local)
        argv = shlex.split(hook) + [kind, session, host or "", part or "",
                                    "local" if local else "remote"]
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, start_new_session=True)
            out, err = await asyncio.wait_for(proc.communicate(), TIMEOUT)
        except asyncio.TimeoutError:
            await _reap(proc)
            print(f"mux-desktop-notifier: toast hook timed out", flush=True)
            return self.text(host, session, kind, local)
        except OSError as e:
            print(f"mux-desktop-notifier: toast hook failed: {e}", flush=True)
            return self.text(host, session, kind, local)
        if proc.returncode != 0 or not out.strip():
            # SAID, not swallowed: a hook that is quietly ignored reads as
            # the seam not working, which is the complaint it exists to fix.
            _m = (err or b"").decode("utf-8", "replace").strip().splitlines()
            print(f"mux-desktop-notifier: toast hook exited "
                  f"{proc.returncode}{': ' + _m[-1] if _m else ''}; "
                  "using the built-in wording", flush=True)
            return self.text(host, session, kind, local)
        lines = out.decode("utf-8", "replace").rstrip("\n").split("\n")
        return lines[0], "\n".join(lines[1:])

    async def announce(self, host, part, session, kind, local=True):
        """Raise one, replacing any we already hold for that session."""
        if not self._enabled:
            return None
        key = (host, part, session)
        summary, body = await self.compose(host, part, session, kind, local)
        try:
            iface = await self._notifications()
            # REPLACING our own previous id rather than stacking: a session
            # that goes blocked, is answered and blocks again should leave one
            # banner, not a column of them. 0 means "a new one".
            prev = self._ids.get(key)
            nid = await iface.call_notify(
                self._app, prev[0] if prev else 0, "", summary, body, [],
                {}, -1)
        except Exception as e:
            # A desktop with no notification daemon is not an error here: the
            # tray is the persistent half of this signal and still works. Said
            # once rather than swallowed, because silence here looks identical
            # to a stream that never announced anything.
            print(f"mux-desktop-notifier: notify failed: {e}", flush=True)
            return None
        self._ids[key] = (nid, kind)
        return nid

    async def withdraw(self, host, part, session):
        if not self._enabled:
            return
        held = self._ids.pop((host, part, session), None)
        if held is None:
            return
        try:
            iface = await self._notifications()
            await iface.call_close_notification(held[0])
        except Exception:
            # Best effort, which the banner's own urgency is what makes safe:
            # banner is at NORMAL urgency so it expires by itself, which is
            # what makes a missed close cost nothing. This is also why
            # `blocked` is not `critical`, a lesson already paid for.
            pass

    def stale(self, host, sessions):
        """Which held banners no longer describe anything true.

        A `blocked` banner stops being true when that pane is no longer
        blocked; a `finished` one when the turn starts again. A session that
        has VANISHED counts too: its pane is gone, so the prompt it announced
        cannot still be waiting.
        """
        out = []
        for (h, part, sess), (_nid, kind) in self._ids.items():
            if h != host:
                continue
            state = (sessions.get(part) or {}).get(sess)
            if kind == "blocked":
                if state != "blocked":
                    out.append((h, part, sess))
            elif state not in ("idle", "humming"):
                out.append((h, part, sess))
        return out

    async def sync(self, host, sessions):
        """Withdraw every banner this host's latest answer has outdated."""
        for key in self.stale(host, sessions):
            await self.withdraw(*key)


class Feed:
    """One host's answer, shared by every item that host publishes.

    ONE QUERY PER HOST PER TICK, not one per partition, which is the whole
    argument for `mux agent-summary --all`: over a transport, N partitions
    must not mean N ssh connections. The items do not poll; they wait on this
    and read their own row out of the result.

    IT ALSO DISCOVERS. The set of partitions is not knowable from here (it
    lives on the other machine), so the same answer that repaints the items
    is what tells the supervisor which items should exist at all. Two
    mechanisms for one fact is how a tray starts disagreeing with itself.
    """

    def __init__(self, argv, stream_argv=None, on_event=None):
        self.argv = argv
        # The streaming form of the same source, when there is one. A feed
        # with it does not poll at all; see `run`.
        self.stream_argv = stream_argv
        # None until the first answer, and again whenever one fails. It is
        # NOT an empty dict: "quiet" and "cannot reach" must stay apart.
        self.rows = None
        # Whether a query has COMPLETED, either way. Not the same question as
        # `rows is None`, which is also true of a host that answered and could
        # not be reached, and the difference decides whether an item paints
        # `unknown` or waits. Without it every item flashed unknown for one
        # tick at startup, before its host had been asked even once.
        self.asked = False
        # Announcements this feed has read and nobody has presented yet, and
        # the per-session states a presenter needs to know when to withdraw
        # one. Both are EMPTY rather than None: "no events" is a fact, where
        # `rows is None` deliberately means "could not ask".
        self.pending = []
        self.sessions = {}
        # Called after every line that could change what a presenter should
        # show. A CALLBACK rather than the supervisor draining on its own
        # timer, because that timer is 5s and a banner five seconds late is a
        # banner about something you have already noticed.
        self.on_event = on_event
        self._ev = asyncio.Event()

    def partitions(self):
        """The partitions this host reported, or None if it has not
        answered. The supervisor keeps the LAST known set when this is None,
        because an unreachable host must keep its items and draw them
        `unknown`: withdrawing them would empty the tray at the exact moment
        it has something to say."""
        return None if self.rows is None else sorted(self.rows)

    def row(self, part):
        """One partition's (state, count).

        UNKNOWN when the host could not be reached AND when it answered
        without mentioning this partition. The second case is not calm: the
        item exists because that partition was there a moment ago, so its
        absence from a successful answer is a fact nobody has explained."""
        if self.rows is None:
            return UNKNOWN
        if part is None:
            # The solo form: one partition, whichever it is called. Named
            # rather than positional would be better and is not available:
            # the key deliberately does not carry it, so that a host gaining
            # a second partition re-keys its item rather than mutating it.
            if len(self.rows) != 1:
                return UNKNOWN
            return next(iter(self.rows.values()))
        return self.rows.get(part, UNKNOWN)

    async def run(self):
        """Keep this host's answer current, by whichever means it supports.

        ONE ENTRY POINT so the supervisor does not have to know which: a
        source gains the ability to stream by appearing in `sources.streams`,
        and nothing about starting or stopping a feed changes.
        """
        if self.stream_argv:
            # `watch` returns ONLY when it has established that this source
            # cannot stream, so falling through is the downgrade.
            await self.watch()
        await self.poll()

    def _ingest(self, line):
        """One line from a stream -> this feed's rows. True if it was an
        ANSWER (so the items should be woken), False for a keepalive.

        A HEARTBEAT IS NOT AN ANSWER AND MUST NOT BE READ AS ONE. It carries
        no `partitions`, so handing it to `parse_all` yields None, which means
        "do not trust this answer" and would blank every item on this host on
        every keepalive: the calm-host signal turned into a flashing unknown.
        It is checked for FIRST and then ignored, carrying liveness only.

        AND A LINE THAT IS NOT AN ANSWER DOES MAKE THIS HOST UNKNOWN. A feed
        emitting junk fast would otherwise never go stale and would hold its
        last good value for ever, which is precisely the bug this whole
        indicator exists to avoid: an unreachable box showing whatever it last
        said. `parse_all` already draws that line; this only has to respect it.

        AND AN ANNOUNCEMENT IS A THIRD KIND, which has to be recognised here
        for exactly the heartbeat's reason: it carries no `partitions`, so
        falling through would blank every item on this host at the moment it
        has something to say. It is not an answer either, so it returns False
        and leaves `rows` alone; the pending event is picked up by `watch`,
        which is the async side that can act on it.

        THE DECISION IS NOT OURS. The watched box has already applied every
        rule about whether a human should be interrupted, because every fact
        those rules need (is this the pane you are looking at, what does the
        layout say, whose attention is owed) is a property of a pane on THAT
        machine at the moment it changed. This end only presents.
        """
        text = line.decode("utf-8", "replace")
        try:
            doc = json.loads(text)
        except (ValueError, TypeError):
            doc = None
        if isinstance(doc, dict) and doc.get("heartbeat"):
            return False
        if isinstance(doc, dict) and isinstance(doc.get("announce"), dict):
            _a = doc["announce"]
            _p, _s = _a.get("partition"), _a.get("session")
            _k = _a.get("kind")
            # VALIDATED, because this crosses a transport and goes on to a
            # notification body: a feed answering junk must not be able to
            # put arbitrary text on the user's desktop. An unknown kind is
            # dropped rather than guessed, which under-reports rather than
            # announcing something mux never meant.
            if (isinstance(_p, str) and isinstance(_s, str)
                    and _k in ("blocked", "finished") and _s
                    and _p not in IGNORE):
                self.pending.append((_p, _s, _k))
            return False
        self.rows = parse_all(text)
        # THE PER-SESSION STATES, kept beside the rows rather than folded into
        # them: `parse_all`'s shape is read in several places and widening it
        # would change every one of them. These exist only so a banner can be
        # CLOSED when the thing it announced stops being true, which is the
        # half emit used to do by carrying an id in the record.
        if self.rows is not None and IGNORE:
            # BOTH SURFACES, because `ignore` naming only the banners would be
            # a filter whose name lies. `parse_all` already drops a name that
            # is not a DNS label, which covers the demo for the tray by
            # accident; this covers it on purpose and covers a real partition
            # somebody wants hidden, which that rule never could.
            for _k in [k for k in self.rows if k in IGNORE]:
                del self.rows[_k]
        self.sessions = {}
        if isinstance(doc, dict) and self.rows is not None:
            for _row in doc.get("partitions") or []:
                if not isinstance(_row, dict):
                    continue
                _pn = _row.get("partition")
                if not isinstance(_pn, str) or _pn in IGNORE:
                    continue
                _by = {}
                for _sr in _row.get("sessions") or []:
                    if not isinstance(_sr, dict):
                        continue
                    _sn, _st = _sr.get("session"), _sr.get("state")
                    if isinstance(_sn, str) and isinstance(_st, str):
                        _by[_sn] = _st
                self.sessions[_pn] = _by
        self.asked = True
        return True

    async def watch(self):
        """Read a long-lived source, repainting on every answer it sends.

        RETURNS when this source has proved it cannot stream, which is the
        caller's signal to poll it instead. A remote may be running a mux too
        old to know the verb: it answers one line of `{"status":"usage"}`,
        exits 2, and without this the host would sit `unknown` for ever while
        being perfectly reachable, respawning a doomed stream every few
        seconds. Plausible, wrong and silent, which is this package's
        signature failure.

        THE DISCRIMINATOR IS A POLL, not a timer and not a version query. An
        unreachable host ALSO fails to stream without answering, and
        downgrading it would spend the feature on a network blip; a remote
        that is merely too old answers a POLL perfectly. So on a stream that
        has NEVER once answered, ask the other channel: it answers, this
        source cannot stream, and if it does not answer the host is simply
        unreachable and the stream is worth retrying. Same move latch makes
        when it cannot read an exit code, for the same reason: on a path that
        is already failing, one read-only round trip is free.

        NEVER ANSWERED, rather than "exited quickly". A stream that worked for
        an hour and then dropped is a disruption and must be retried, not
        downgraded, and no timing rule separates those two.
        """
        _back = RESPAWN
        _ever = False
        while True:
            proc = None
            try:
                proc = await asyncio.create_subprocess_exec(
                    *self.stream_argv,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                    # The PAIR, exactly as `_query` documents: a source is an
                    # arbitrary command and may spawn children that hold the
                    # pipe, and without the new session the group kill in
                    # `_reap` would resolve to the DAEMON's own group.
                    start_new_session=True)
            except OSError:
                proc = None
            if proc is not None:
                try:
                    while True:
                        try:
                            line = await asyncio.wait_for(
                                proc.stdout.readline(), STALE)
                        except asyncio.TimeoutError:
                            break   # silent past the heartbeat: not trusted
                        if not line:
                            break   # the stream ended
                        _ans = self._ingest(line)
                        if self.on_event is not None:
                            try:
                                await self.on_event(self)
                            except Exception as e:
                                # A PRESENTER MUST NOT KILL THE FEED. The
                                # tray is the persistent half of this signal
                                # and goes on being right even if a banner
                                # cannot be raised, so a failure here is said
                                # and dropped.
                                print("mux-desktop-notifier: "
                                      f"event failed: {e}", flush=True)
                        if _ans:
                            _back = RESPAWN
                            # USABLE, not merely "worth repainting".
                            # `_ingest` answers True for any line that is not
                            # a keepalive, INCLUDING one that set rows to
                            # None, and a mux too old to know the verb emits
                            # exactly such a line (`{"status":"usage"}`).
                            # Counting that as having streamed is what made
                            # the first version of this skip the fallback
                            # entirely, for precisely the case it exists for.
                            if self.rows is not None:
                                _ever = True
                            self._ev.set()
                            self._ev.clear()
                finally:
                    await _reap(proc)
            # The stream is gone, or went quiet past the point of belief.
            # NOTHING CAN BE CLAIMED about this host until it comes back, and
            # saying so is the whole reason the heartbeat exists.
            self.rows = None
            self.asked = True
            self._ev.set()
            self._ev.clear()
            if not _ever:
                probe = await _query_all(self.argv)
                if probe is not None:
                    self.rows = probe
                    self.asked = True
                    self._ev.set()
                    self._ev.clear()
                    return      # reachable and cannot stream: poll it
            await asyncio.sleep(_back)
            _back = min(_back * 2, RESPAWN_MAX)

    async def poll(self):
        """Query forever, waking this host's items after each answer."""
        while True:
            self.rows = await _query_all(self.argv)
            self.asked = True
            self._ev.set()
            self._ev.clear()
            await asyncio.sleep(POLL)

    async def changed(self):
        await self._ev.wait()


async def _host_colors(label):
    """`mux host-color LABEL` -> an (fg, bg) pair, or None.

    RUN LOCALLY, even for a remote host, and that is the point rather than a
    shortcut: the colour derives from the NAME by hashing, so the box you are
    sitting at can colour a remote host correctly with nothing shared and
    nothing configured. Asking the remote would need it reachable just to pick a
    colour, so an unreachable host would lose its identity at the exact moment
    the `unknown` glyph needs to say WHICH host is unreachable.

    None on any failure, including the deliberate refusal for colours 0-15.
    A tray item drawing the neutral look is a small loss; a wrong colour on the
    thing whose whole job is identifying a machine is a real one.
    """
    if not label:
        return None
    try:
        proc = await asyncio.create_subprocess_exec(
            MUX, "host-color", label,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except (OSError, asyncio.TimeoutError):
        return None
    if proc.returncode != 0:
        return None
    return parse_pair(out.decode("utf-8", "replace"))


async def _reap(proc):
    """Kill a timed-out child AND everything it spawned.

    ONE COPY, because there are two callers now (a poll and a click) and the
    rules below were learned the hard way: a second copy is a second place
    for them to rot. It also stopped the mutation corpus naming which one it
    meant: the duplicated killpg made an existing record's anchor ambiguous
    and the rider said so.
    """
    try:
        # THE GROUP ID IS THE CHILD'S OWN PID, and asking the kernel for it
        # instead is a bug. `start_new_session=True` makes the child a session
        # and process-group LEADER, so pgid == pid by definition.
        #
        # `os.getpgid(proc.pid)` raises ProcessLookupError the moment the
        # direct child has exited and been reaped, which is EXACTLY the case
        # this exists for: a wrapper that backgrounds its work and returns is
        # reaped by asyncio's child watcher within milliseconds, long before a
        # timeout fires. The group kill was then skipped entirely and the
        # fallback ran against a process already gone, so every descendant
        # still holding the stdout pipe SURVIVED: one leaked process per poll,
        # for as long as the host stayed in that state. Measured 2026-09-26.
        #
        # A process GROUP outlives its reaped leader while it still has
        # members, so killing by pid-as-pgid reaches them.
        os.killpg(proc.pid, SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            proc.kill()
        except (OSError, ProcessLookupError):
            pass
    # BOUNDED even so. The group kill should make this immediate, but the
    # caller's one promise is that it always answers, and an unbounded wait
    # here would break that promise while looking careful.
    try:
        await asyncio.wait_for(proc.wait(), 2)
    except (asyncio.TimeoutError, OSError, ProcessLookupError):
        pass


async def activate(label):
    """A click on one item: switch that host, then let the integrator focus.

    TWO HALVES, and only the first is mux's. Switching the client is what mux
    legitimately owns and works over the same transport the item is already
    polled with: a tray item EXISTS only because a latch does, so there is a
    client attached and a human looking at it.

    Raising the terminal that shows it is NOT mux's: that means knowing about
    a compositor, and mux manages sessions inside terminals with no opinion
    about where a terminal sits. It goes through the activate hook, unset by
    default, so a click still does the half mux owns when nobody wired one.
    """
    me = local_label()
    host, part = host_of(label), part_of(label)
    if host and host != me:
        argv = remote_argv(host, cmd=activate_cmd(part))
    else:
        argv = [MUX, "next-blocked"]
        if part:
            argv += ["--partition", part]
    await _fire(argv, f"switch {label or me}")

    hook = activate_hook()
    if hook:
        # THE HOST, NOT THE KEY, as the hook's first argument. The shipped
        # examples match a terminal title against `[host]`, which is what mux
        # itself puts there: a `host:partition` key would match nothing and
        # the click would silently stop raising the window. The partition
        # follows as a second argument, which an existing hook ignores and a
        # new one can use.
        #
        # Shell-SPLIT rather than run through a shell: the hook is a command
        # line in config, not a script, and handing it to `sh -c` would make a
        # host name with a space an injection rather than an argument.
        args = [host or me] + ([part] if part else [])
        # RESOLVED, because the samples are not on PATH. config.sample
        # documents `desktop-notifier-activate kitty`, and that bare name
        # installs under $MUX_SHARE/desktop-notifier/focus/, so exec could
        # never find it and the click reported "failed to start" about a file
        # sitting on disk. `none` disables the seam and answers None here.
        #
        # `focus`, SO A FOCUS VALUE CANNOT RESOLVE A TOAST HOOK: the seam is
        # the directory, and a banner composer handed a tray label would
        # print to stdout and report success having raised nothing.
        _h = hook_path(hook, "focus")
        if _h:
            await _fire(shlex.split(_h) + args, f"focus {label or me}")


async def _fire(argv, what):
    """Run something on a click, bounded, and never raise into the bus.

    The same reaping rules as _query, for the same reason: an arbitrary
    command may spawn a child that holds the pipe, so it gets its own session
    and the whole GROUP is killed by pid: see _query for why the pid and not
    getpgid. A click that hangs would wedge the poll loop it shares.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE, start_new_session=True)
    except OSError as e:
        print(f"mux-desktop-notifier: {what} failed to start: {e}", flush=True)
        return
    try:
        _o, err = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except asyncio.TimeoutError:
        await _reap(proc)
        print(f"mux-desktop-notifier: {what} timed out", flush=True)
        return
    if proc.returncode != 0:
        # SAID OUT LOUD. A click that silently does nothing is the worst
        # outcome: it reads as the feature not existing.
        _msg = (err or b"").decode("utf-8", "replace").strip().splitlines()
        print(f"mux-desktop-notifier: {what} exited {proc.returncode}"
              f"{': ' + _msg[-1] if _msg else ''}", flush=True)


def item_set(hosts, feeds, known):
    """-> {key: (feed, part, letter)}: every item that should exist right now.

    Lifted out of the supervisor for the same reason `reconcile` and
    `mark_plan` were: the loop is async and needs a bus, so a rule left inside
    it cannot be asserted, and this is where the whole partition feature is
    decided.

    AN UNREACHABLE HOST KEEPS ITS ITEMS. The partition set lives on the other
    machine, so a failed query means "could not ask", never "it has none",
    and withdrawing the items would empty the tray at the exact moment it has
    something to say. They stay, and the feed draws them `unknown`, which is
    the whole promise of the cross-machine design. `known` carries the last
    answer forward for that; it is mutated here rather than returned because
    it is the caller's memory across ticks.

    A HOST THAT HAS NEVER ANSWERED PUBLISHES NOTHING, one tick only. Nothing
    is known about it yet, not even how many items it wants, and inventing one
    would mean withdrawing or re-keying it a second later.
    """
    want = {}
    for host in hosts:
        feed = feeds[host][0]
        parts = feed.partitions()
        if parts is None:
            parts = known.get(host)
            if parts is None:
                continue
        else:
            known[host] = parts
        solo = len(parts) < 2
        letters = partition_letters(parts)
        for part in parts:
            want[item_key(host, part, solo)] = (
                feed, None if solo else part, letters.get(part))
    return want


def reconcile(want, live):
    """-> (drop, add): labels to withdraw, and (label, argv) pairs to publish.

    Lifted out of the supervisor for the same reason mark_plan was: the loop
    needs a bus, so nothing left inside it can be asserted, and this is the
    decision the whole daemon turns on.

    THE RULE THAT IS NOT OBVIOUS IS THE THIRD ONE: a label in BOTH is left
    exactly alone. Tearing an item down and republishing it every tick would
    still converge on the right set, so no set-based assertion would notice,
    while the tray flickered every DISCOVER seconds and leaked a bus connection
    per host per pass. "Already correct" has to mean "untouched", not
    "recreated identically".
    """
    drop = [lab for lab in live if lab not in want]
    add = [(lab, argv) for lab, argv in want.items() if lab not in live]
    return drop, add


# LOCAL SORTS FIRST, and a hyphen is the only prefix that reliably does it.
# Most trays alpha-sort by Id and offer no way to say otherwise, so position is
# bought in the string or not at all. In ASCII `-` is 0x2D, BELOW the digits
# (0x30), the uppercase letters (0x41) and the lowercase ones (0x61), so it
# beats any legal hostname. `_` (0x5F) does not: it loses to `7bravo` and to
# every capitalised name. A leading digit loses to a lower digit. Measured
# rather than assumed, because the obvious two both look fine against a set of
# ordinary lowercase names and fail on the first host somebody names `Atlas`.
_LOCAL_SORT = "-"


def item_id(label, local=False):
    """The tray Id: `mux-<label>`, and `mux--<label>` for the local host.

    SELF-DESCRIBING ON THE BUS, which is the point of carrying the label at
    all: a human reading the watcher's item list can tell which host each item
    speaks for without introspecting it. The `mux-` prefix a bar can order on
    survives the sort prefix, so an `order` array keyed on it still matches.
    """
    if not label:
        # NOT RENAMED WITH THE PACKAGE, deliberately: this is a BUS id and a
        # bar's `order` array may name it, so it is a published contract with
        # something outside this repo rather than a spelling of our own. A
        # label is always set in practice, so it is reached by nothing here.
        return "mux-indicator"                 # the historical unlabelled id
    return f"mux-{_LOCAL_SORT if local else ''}{label}"


def item_bus_name(pid, index):
    """The SNI bus name for one item.

    ONE-BASED, matching the convention every other SNI producer uses, and the
    `-1` suffix in `org.kde.StatusNotifierItem-<pid>-1` is a per-process item
    INDEX, which is what makes several items from one process legal at all.
    """
    return f"org.kde.StatusNotifierItem-{pid}-{index}"


def wants_reregister(name, new_owner):
    """Should a NameOwnerChanged signal make us announce ourselves again?

    Only for the WATCHER, and only when it ARRIVES. Re-registering on every
    name change on the session bus would be a storm; doing it when `new_owner`
    is empty would fire on the watcher DEPARTING, which is when registering is
    both pointless and guaranteed to fail.
    """
    return name == WATCHER and bool(new_owner)


def mark_plan(labels, local, slots):
    """-> {label: (mark, ink)} for the whole tray at once.

    A PURE FUNCTION, deliberately lifted out of the supervisor's loop: the loop
    is async and needs a bus, so anything left inside it is untestable, and the
    two rules below are the whole feature. mux has already paid for this once,
    when both shipped latch hooks turned out never to have executed because
    every test stubbed the seam around them.

    ONE HOST NEEDS NO MARK. It exists to tell several apart, so a single-host
    tray (the common case, and every new user's first impression) keeps
    exactly the look it always had, tint and all.

    COUNTED IN HOSTS, NOT ITEMS, which is the 0.56 correction. One host with
    two partitions publishes two items, and marking them would put the same
    three letters and the same colour on both: it says nothing, because they
    ARE the same machine. The partition letter is what tells those two apart,
    and the mark stays for the question it actually answers.

    THE LOCAL HOST TAKES NO SLOT, which is what reserves white for it. Matched
    by NAME rather than by position: `labels` comes from a dict, so a host that
    drops and returns re-enters somewhere else and would otherwise inherit
    whichever identity happened to sit at that index.
    """
    if len({host_of(lab) for lab in labels}) < 2:
        return {lab: (None, None) for lab in labels}
    return {lab: (host_mark(host_of(lab)),
                  None if host_of(lab) == local else slots.slot(host_of(lab)))
            for lab in labels}


async def _watch(item, feed, part=None, label=""):
    """Feed one icon: the override file if present, else this item's row out
    of its host's answer. Only repaints when the (state, count) actually
    changes.

    IT WAITS ON THE FEED rather than sleeping POLL of its own. Two items on
    one host would otherwise drift out of phase with the answer they share and
    with each other, so a change would reach one tile up to a whole tick
    before the other: on the same machine, from the same query.
    """
    last = None
    while True:
        if not feed.asked:
            # NOT YET ASKED is not `unknown`. Painting before the first answer
            # lands would flash every item at startup, and unknown means "this
            # host was asked and could not be reached".
            await feed.changed()
            continue
        cur = _read_override() or feed.row(part)
        if cur != last:
            last = cur
            item.set(*cur)
            print(f"mux-desktop-notifier: {label or 'local'} = "
                  f"{cur[0]} {cur[1]}", flush=True)
        await feed.changed()


def _backend():
    """WHICH PRESENTER THIS PLATFORM HAS, resolved once and cached.

    THE ONLY PLACE A PLATFORM IS NAMED. A backend owes three things and
    nothing else: `session_bus()`, `toaster(bus, enabled)` and
    `export(index, tile, activate) -> handle`, where the handle answers
    `close()`. Everything above this line decides WHAT to show and works on a
    machine with no bus, which is the property that makes a macOS presenter a
    sibling of backend_dbus rather than a fork of this file.

    IMPORTED LAZILY, and that is load-bearing rather than tidy: backend_dbus
    is the one module that needs dbus_next, so importing it at the top would
    put that dependency back on every reader of this file and take the 147
    tests with it.
    """
    global _BACKEND
    if _BACKEND is None:
        from . import backend_dbus
        _BACKEND = backend_dbus
    return _BACKEND


_BACKEND = None


async def _publish(index, label, feed, part=None):
    """One tile, published by whatever presenter this platform has, plus the
    watch task that feeds it.

    The item's poll is not its own any more: it reads `feed`, which its whole
    HOST shares, so two partitions on one box cost one query rather than two.
    """
    # Before the export, so the FIRST pixmap a tray host reads already carries
    # the host colour. Painting neutral and then correcting it would make every
    # item visibly change colour a moment after the bar appeared.
    #
    # THE HOST HALF OF THE KEY, because the colour identifies a MACHINE: two
    # partitions on one box must be the same colour, or the tray says they are
    # two machines and the letter says they are not.
    host = await _host_colors(host_of(label))
    if host is None and label:
        print(f"mux-desktop-notifier: {label} has no usable colour pair "
              f"(drawing host-neutral)", flush=True)
    tile = Tile(label=label, host=host, part=part,
                local=(host_of(label) == local_label()))
    handle = await _backend().export(index, tile, activate)
    task = asyncio.create_task(_watch(tile, feed, part, label))
    return handle, task, tile


async def _supervise():
    """Keep the published set matching the discovered set, forever.

    THE SET IS LIVE NOW, which is the whole point of reading latch's locks
    rather than a config file: latch to a box and its item appears; detach and
    it goes. Nothing is stood up or torn down by hand, and nothing has to be
    edited per machine.

    WITHDRAWING IS DISCONNECTING. A tray host drops an item when its bus name
    goes away, so closing the connection is the withdrawal: there is no
    "unregister" in the SNI spec. Verified against a live waybar.

    THE BUS NAME INDEX ONLY EVER GOES UP. Reusing the index of a departed host
    would hand a tray host a name it may still be holding state for, and the
    spec's name is meant to be unique per item; a counter costs nothing.
    """
    live = {}          # key -> (bus, task, item)
    feeds = {}         # host -> (Feed, task)
    known = {}         # host -> its last KNOWN partition list
    index = 0
    announced = False
    # ONE Slots FOR THE PROCESS, so the in-memory table is the same object
    # every tick. Re-reading the file per pass would work and would also mean a
    # host assigned this tick is invisible to the next one until the write
    # lands, which is a race for nothing.
    _slots = Slots(len(MARK_PALETTE))
    # ONE TOASTER FOR THE PROCESS, on its own connection, because it holds the
    # notification ids: a per-host one would lose them on every reconnect and
    # leave banners nobody can withdraw. `TOASTS` off makes it inert rather
    # than absent, so nothing downstream needs to know.
    _toast_bus = await _backend().session_bus()
    _toaster = _backend().toaster(_toast_bus, enabled=TOASTS)
    _local = sources.local_label()

    async def _present(feed):
        """Everything a feed read that a human should be shown.

        WITHDRAW BEFORE RAISING, deliberately: a session that finishes and
        immediately starts again should not have its new banner replaced by
        the withdrawal of its old one. The order is the only thing keeping
        those two straight, since both act on the same key.
        """
        _hn = getattr(feed, "host", None)
        if feed.rows is not None:
            await _toaster.sync(_hn, feed.sessions)
        while feed.pending:
            _pt, _ps, _pk = feed.pending.pop(0)
            await _toaster.announce(_hn, _pt, _ps, _pk,
                                    local=(_hn == _local))

    while True:
        try:
            hosts = dict(load_sources(mux_bin=MUX))
            _streams = dict(load_streams(mux_bin=MUX))
        except Exception as e:
            # Discovery failing must never take the daemon down: the items
            # already published are still telling the truth.
            print(f"mux-desktop-notifier: discovery failed: {e}", flush=True)
            await asyncio.sleep(DISCOVER)
            continue

        # ONE FEED PER HOST, started before anything it owns is published and
        # stopped when the last of them goes. The feed is what discovers the
        # partitions, so a host's first tick necessarily publishes nothing:
        # the item set arrives one pass later, which is imperceptible and is
        # the price of not asking a second question to find out what to ask.
        for _h, _argv in hosts.items():
            if _h not in feeds:
                _f = Feed(_argv, _streams.get(_h), on_event=_present)
                # The feed carries its own label, so one presenter serves
                # every host without a closure per feed.
                _f.host = _h
                feeds[_h] = (_f, asyncio.create_task(_f.run()))
        for _h in [h for h in feeds if h not in hosts]:
            _f, _t = feeds.pop(_h)
            _t.cancel()
            known.pop(_h, None)

        want = item_set(hosts, feeds, known)

        # WITH THE TRAY OFF, NOTHING IS PUBLISHED AND THE FEEDS STILL RUN.
        # The feeds are what the toasts come from, so suppressing the icon
        # must not suppress the signal: `want` going empty makes `reconcile`
        # withdraw whatever is up and add nothing, which is the same path a
        # detach already takes rather than a second way to not draw.
        if not TRAY:
            want = {}
        drop, add = reconcile(want, live)

        # ANNOUNCED OFF THE SAME DIFF, rather than recomputing `set(want) !=
        # set(live)` beside it: two expressions for one fact is how the log
        # starts disagreeing with what the daemon actually did.
        if not announced or drop or add:
            _names = ", ".join(sorted(want)) or "none"
            print(f"mux-desktop-notifier: watching {_names}", flush=True)
            announced = True

        for label in drop:
            handle, task, _item = live.pop(label)
            task.cancel()
            handle.close()
            # The reason is no longer always a latch: an item also goes
            # when its partition stops being reported, and when a host
            # gains a second one and every key on it is rewritten.
            print(f"mux-desktop-notifier: - {label} (withdrawn)", flush=True)

        for label, (_feed, _part, _letter) in add:
            index += 1
            try:
                live[label] = await _publish(index, label, _feed, _part)
            except Exception as e:
                # One host that cannot be published must not cost the others,
                # and the others are exactly where its absence would show.
                print(f"mux-desktop-notifier: could not publish {label}: {e}",
                      flush=True)

        # AFTER publishing, not before: a host joining is the tick that turns
        # the marks ON, and marking only the previously-live items would leave
        # the newcomer blank until the next pass: the one item you are
        # looking at precisely because it just appeared.
        plan = mark_plan(live, local_label(), _slots)
        for _label, (_h, _t, _item) in live.items():
            _mk, _ink = plan[_label]
            _item.set_mark(_mk, _ink, want[_label][2] if _label in want
                           else None)
        await asyncio.sleep(DISCOVER)


def flags(argv, tray=None, toasts=None, ignore=None):
    """argv -> (tray, toasts, ignore). A PURE FUNCTION, so the one thing
    a daemon
    cannot be asked twice about is testable without starting one.

    THE FLAG WINS OVER THE ENVIRONMENT, which is this fleet's own precedence
    read correctly for once: a flag is passed by whoever launched this
    process, an environment variable is inherited from whatever launched it,
    and the more specific of the two is the flag. An unknown argument is
    REFUSED rather than ignored, because `setup.sh install PREFIX=...` taught
    this repo that an installer which ignores an argument installs somewhere
    else and says it worked.
    """
    tray = TRAY if tray is None else tray
    toasts = TOASTS if toasts is None else toasts
    ignore = set(IGNORE if ignore is None else ignore)
    _pend = None
    for a in argv:
        if _pend == "ignore":
            # `none` CLEARS rather than adding a partition called `none`,
            # which is the same word the config uses for the same reason: a
            # partition is a DNS label, so `none` is a legal name and the
            # collision is real, but one nobody will meet and the alternative
            # is a second spelling of "ignore nothing".
            if a == "none":
                ignore = set()
            else:
                ignore.add(a)
            _pend = None
            continue
        if a == "--no-tray":
            tray = False
        elif a == "--no-toasts":
            toasts = False
        elif a == "--tray":
            tray = True
        elif a == "--toasts":
            toasts = True
        elif a == "--ignore":
            _pend = "ignore"
        else:
            raise SystemExit(f"mux-desktop-notifier: unknown argument '{a}'\n"
                             "usage: mux-desktop-notifier "
                             "[--no-tray] [--no-toasts]")
    if _pend is not None:
        raise SystemExit("mux-desktop-notifier: --ignore needs a partition "
                         "name (or `none`)")
    return tray, toasts, frozenset(ignore)


async def run():
    await _supervise()
