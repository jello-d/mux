"""The StatusNotifierItem D-Bus service (org.kde.StatusNotifierItem).

Exports ONE TRAY ITEM PER SOURCE and updates each live: on a state/count change
it re-renders the owned pixmap and emits NewIcon/NewStatus so the host (waybar's
tray, or any DE's) repaints. State comes from each source's command (normally
`mux agent-summary`: the aggregate worst state + count across that host's
sessions), polled on a timer. A manual override file takes precedence when
present, for testing without live sessions.

N ITEMS FROM ONE PROCESS, and it has to be a CONNECTION EACH. A single
connection can own several bus names, but `RegisterStatusNotifierItem` takes a
service NAME and nothing else -- the watcher then looks for /StatusNotifierItem
on it -- so two names on one connection resolve to the same exported object and
you get the same item twice. Measured against a live waybar: two connections
from one pid registered as two items and drew as two. The `-1` in
`org.kde.StatusNotifierItem-<pid>-1` is a per-process item INDEX, so the naming
convention anticipated exactly this.

EACH SOURCE POLLS INDEPENDENTLY. One task per item rather than a gather, so a
host that is slow to answer delays only its own icon. A shared round would make
every host as slow as the worst one, which over ssh is the normal case.
"""
import asyncio
import os
# SIGKILL by NAME, not the `signal` module: dbus_next.service exports a `signal`
# DECORATOR (imported below) which shadows it, so `signal.SIGKILL` raises
# AttributeError. That is not caught by the OSError/ProcessLookupError guard at
# the call site, so it would have escaped _query, killed that host's poll task,
# and frozen its icon -- on the TIMEOUT path, meaning it would only ever have
# fired the moment a host became unreachable.
from signal import SIGKILL

from dbus_next import BusType, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

from .render import MARK_PALETTE, host_mark, icon_pixmap, parse_pair
from .slots import Slots
from .sources import load as load_sources, local_label

WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
# State feed. MUX runs `mux agent-summary` ("<state> <count>") as the live
# source, polled every POLL seconds. CTL is an OPT-IN manual override file for
# testing: set MUX_INDICATOR_CTL to a path and write "<state> <count>" into it
# to force a value. UNSET by default -- so the deployed service reads ONLY the
# live feed and no stray /tmp file can silently pin it.
MUX = os.environ.get("MUX_BIN", "mux")
# 5s, not the 1.5s of the single-local-host days: a source may be an ssh round
# trip now, and polling a remote box thrice a second is rude for a signal that
# changes on human timescales.
POLL = float(os.environ.get("MUX_INDICATOR_POLL", "5"))
# A SOURCE THAT HANGS MUST STILL ANSWER. ssh into a blackholed host does not
# fail, it SLEEPS -- so without a deadline that item would freeze on its last
# value forever, showing a calm icon for a machine that fell off the network.
# That is the precise failure this indicator exists to prevent, so the timeout
# is not a nicety; it is what makes `unknown` reachable.
TIMEOUT = float(os.environ.get("MUX_INDICATOR_TIMEOUT", "10"))
CTL = os.environ.get("MUX_INDICATOR_CTL")
# How often to re-read latch's lock directory. Slower than POLL on purpose: this
# is a listdir of a tmpfs, but a host appearing a few seconds after you latch is
# imperceptible, while an item flickering in and out is not.
DISCOVER = float(os.environ.get("MUX_INDICATOR_DISCOVER", "5"))
# On a state/count change the `_` cursor blinks BLINK_N times at BLINK_MS each,
# to catch the eye, then settles cursor-on.
BLINK_N = int(os.environ.get("MUX_INDICATOR_BLINK", "5"))
BLINK_MS = int(os.environ.get("MUX_INDICATOR_BLINK_MS", "250"))


class Indicator(ServiceInterface):
    def __init__(self, state="none", count=None, label=None, host=None):
        super().__init__("org.kde.StatusNotifierItem")
        # The label names the host this item speaks for. None keeps the old
        # unlabelled identity, which is what the existing tests construct.
        self._label = label
        # The (fg, bg) identity pair, or None for the host-neutral look. Fixed
        # for this item's life: it derives from the NAME by hashing, so it
        # cannot change while the daemon runs, and re-querying it per poll would
        # be a subprocess per host per tick for an answer that never moves.
        self._host = host
        # The three-character host mark, or None for the single-host look.
        # Set later too: it appears when a second host joins the tray and goes
        # again when you detach, so one item never carries a label it does not
        # need.
        self._mark = None
        # The palette slot the mark wears, or None for the LOCAL host. Carried
        # beside the mark because the two turn on together and neither means
        # anything without the other.
        self._ink = None
        self._state = state
        self._count = count
        self._pixmap = icon_pixmap(state, count, host=host)
        self._blink = None

    def _status(self):
        return "NeedsAttention" if self._state == "blocked" else "Active"

    def _paint(self, cursor=True):
        self._pixmap = icon_pixmap(self._state, self._count, cursor=cursor,
                                   host=self._host, mark=self._mark,
                                   ink=self._ink)
        self.NewIcon()

    def set_mark(self, mark, ink=None):
        """Show or hide the host mark. Repaints only on a real change, so the
        discovery loop can call this every tick without churning the tray.

        BOTH fields decide that. Comparing only the mark would pin a host to
        the first colour it was ever drawn with, and a reshuffle would then be
        invisible until something else forced a repaint."""
        if mark == self._mark and ink == self._ink:
            return
        self._mark, self._ink = mark, ink
        self._paint()

    def set(self, state, count):
        """Update the icon live: re-render, tell the host to repaint, then blink
        the cursor a few frames to catch the eye."""
        self._state, self._count = state, count
        self._paint()
        self.NewStatus(self._status())
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

    @dbus_property(access=PropertyAccess.READ)
    def Category(self) -> "s":
        return "ApplicationStatus"

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> "s":
        # `mux-<label>`, so the id is SELF-DESCRIBING on the bus: a human
        # reading the watcher's item list can tell which host each speaks for
        # without introspecting it, which is exactly what you want when working
        # out why one icon is stale. It also keeps the `mux-` prefix a bar can
        # order on. Unlabelled stays `mux-indicator`, the historical id.
        return f"mux-{self._label}" if self._label else "mux-indicator"

    @dbus_property(access=PropertyAccess.READ)
    def Title(self) -> "s":
        return f"mux @ {self._label}" if self._label else "mux"

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> "s":
        return self._status()

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def IconPixmap(self) -> "a(iiay)":
        return self._pixmap

    @dbus_property(access=PropertyAccess.READ)
    def OverlayIconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def AttentionIconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def AttentionIconPixmap(self) -> "a(iiay)":
        return self._pixmap

    @dbus_property(access=PropertyAccess.READ)
    def ToolTip(self) -> "(sa(iiay)ss)":
        # The TITLE carries the host, because with several items in a tray
        # "mux" alone identifies nothing -- the one thing you want on hover is
        # WHICH machine this is.
        if self._state == "unknown":
            body = "cannot reach this host"
        elif self._count is None:
            body = "all sessions idle"
        else:
            body = f"{self._count} session(s): {self._state}"
        title = f"mux @ {self._label}" if self._label else "mux"
        return ["", [], title, body]

    @dbus_property(access=PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        # No dbusmenu yet -> left-click Activate is the whole interaction. The
        # per-session menu (com.canonical.dbusmenu) is a later feature; until
        # then we advertise no Menu property so a host doesn't introspect one.
        return False

    @method()
    def Activate(self, x: "i", y: "i"):
        print(f"mux-indicator: Activate at {x},{y}", flush=True)

    @method()
    def SecondaryActivate(self, x: "i", y: "i"):
        print(f"mux-indicator: SecondaryActivate at {x},{y}", flush=True)

    @method()
    def Scroll(self, delta: "i", orientation: "s"):
        print(f"mux-indicator: Scroll {delta} {orientation}", flush=True)

    @signal()
    def NewIcon(self):
        pass

    @signal()
    def NewStatus(self, status) -> "s":
        return status


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


def _read_override():
    """The opt-in override file (MUX_INDICATOR_CTL) if set + parseable, else
    None -- so with the env unset the live feed is the only source."""
    if not CTL:
        return None
    try:
        # `with` rather than `open(CTL).read()`. On CPython the bare form is
        # not a leak -- refcounting closes the handle the moment .read()
        # returns -- so the ResourceWarning the test run surfaced was about
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
# NOT PARANOIA -- measured. A mis-quoted ssh source ran the bare session PICKER
# on the far side (ssh concatenates its args and the remote shell re-splits, so
# `sh -lc` `mux agent-summary` became `sh -lc mux` with `agent-summary` as $0).
# Its output parsed to the state `1)`, which the renderer draws with the `none`
# fallback: a calm grey tile for a host whose feed is misconfigured. It happened
# to exit non-zero and so read as unknown anyway, but that was luck. A feed that
# returns plausible garbage and exits 0 is the failure this closes.
KNOWN = ("blocked", "working", "idle", "none")


async def _query(argv):
    """Run one source -> (state, count). NEVER None.

    THE EXIT CODE IS THE WHOLE POINT, and ignoring it was the bug this replaces.
    `mux agent-summary` prints `none 0` and exits 0 on a host with no agents, so
    EMPTY IS EXIT 0 and a quiet host is a real answer. A non-zero exit therefore
    has no meaning of its own -- it can only be the transport -- so it must
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
            # grandchild exits -- 30s against a `sh -c "sleep 30"` source, with
            # the timeout itself firing correctly at 0.3s. That stalls this
            # host's poll loop for the grandchild's whole life, which is the
            # very freeze the timeout exists to prevent, reintroduced through
            # the reaping path. A source is an arbitrary command, so a
            # wrapper that spawns a child is not an edge case.
            start_new_session=True)
    except OSError:
        return UNKNOWN
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except asyncio.TimeoutError:
        # Reap it rather than leaving a wedged ssh per poll, which over hours
        # would be a process leak dressed up as a slow host.
        try:
            os.killpg(os.getpgid(proc.pid), SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                proc.kill()
            except (OSError, ProcessLookupError):
                pass
        # BOUNDED even so. The group kill should make this immediate, but this
        # function's one promise is that it always answers, and an unbounded
        # wait here would be a way to break that promise while looking careful.
        try:
            await asyncio.wait_for(proc.wait(), 2)
        except (asyncio.TimeoutError, OSError, ProcessLookupError):
            pass
        return UNKNOWN
    if proc.returncode != 0:          # the transport failed, not the host
        return UNKNOWN
    got = _parse(out.decode("utf-8", "replace"))
    # _parse stays a pure text->tuple function and passes any word through;
    # deciding whether to TRUST it belongs here, with the exit code.
    if got is None or got[0] not in KNOWN:
        return UNKNOWN
    return got


async def _host_colors(label):
    """`mux host-color LABEL` -> an (fg, bg) pair, or None.

    RUN LOCALLY, even for a remote host, and that is the point rather than a
    shortcut: the colour derives from the NAME by hashing, so the box you are
    sitting at can colour a remote host correctly with nothing shared and
    nothing configured. Asking the remote would need it reachable just to pick a
    colour -- so an unreachable host would lose its identity at the exact moment
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


def mark_plan(labels, local, slots):
    """-> {label: (mark, ink)} for the whole tray at once.

    A PURE FUNCTION, deliberately lifted out of the supervisor's loop: the loop
    is async and needs a bus, so anything left inside it is untestable, and the
    two rules below are the whole feature. mux has already paid for this once,
    when both shipped latch hooks turned out never to have executed because
    every test stubbed the seam around them.

    ONE HOST NEEDS NO MARK. It exists to tell several apart, so a single-host
    tray -- the common case, and every new user's first impression -- keeps
    exactly the look it always had, tint and all.

    THE LOCAL HOST TAKES NO SLOT, which is what reserves white for it. Matched
    by NAME rather than by position: `labels` comes from a dict, so a host that
    drops and returns re-enters somewhere else and would otherwise inherit
    whichever identity happened to sit at that index.
    """
    if len(labels) < 2:
        return {lab: (None, None) for lab in labels}
    return {lab: (host_mark(lab),
                  None if lab == local else slots.slot(lab))
            for lab in labels}


async def _watch(item, argv, label=""):
    """Feed one icon: the override file if present, else this item's source.
    Only repaints when the (state, count) actually changes."""
    last = None
    while True:
        cur = _read_override() or await _query(argv)
        if cur != last:
            last = cur
            item.set(*cur)
            print(f"mux-indicator: {label or 'local'} = "
                  f"{cur[0]} {cur[1]}", flush=True)
        await asyncio.sleep(POLL)


async def _publish(index, label, argv):
    """One connection, one bus name, one item, one poll task.

    A CONNECTION EACH is not a style choice: see the module docstring. The bus
    name index is 1-based to match the convention every other SNI producer uses.
    """
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    # Before the export, so the FIRST pixmap a tray host reads already carries
    # the host colour. Painting neutral and then correcting it would make every
    # item visibly change colour a moment after the bar appeared.
    host = await _host_colors(label)
    if host is None and label:
        print(f"mux-indicator: {label} has no usable colour pair "
              f"(drawing host-neutral)", flush=True)
    item = Indicator(label=label, host=host)
    bus.export(ITEM_PATH, item)
    name = f"org.kde.StatusNotifierItem-{os.getpid()}-{index}"
    await bus.request_name(name)

    async def register():
        try:
            intro = await bus.introspect(WATCHER, WATCHER_PATH)
            obj = bus.get_proxy_object(WATCHER, WATCHER_PATH, intro)
            w = obj.get_interface(WATCHER)
            await w.call_register_status_notifier_item(name)
            print(f"mux-indicator: + {label} ({name})", flush=True)
        except Exception as e:
            print(f"mux-indicator: register failed for {label}: {e}",
                  flush=True)

    # (Re)register whenever the tray watcher (waybar) appears, so a `wb restart`
    # or a late-starting bar never leaves us invisible. Per connection, because
    # each name has to re-announce itself.
    di = await bus.introspect("org.freedesktop.DBus", "/org/freedesktop/DBus")
    dobj = bus.get_proxy_object("org.freedesktop.DBus",
                                "/org/freedesktop/DBus", di)
    dbus = dobj.get_interface("org.freedesktop.DBus")

    def on_owner(n, old, new):
        if n == WATCHER and new:
            asyncio.get_event_loop().create_task(register())
    dbus.on_name_owner_changed(on_owner)

    try:
        owner = await dbus.call_get_name_owner(WATCHER)
    except Exception:
        owner = ""
    if owner:
        await register()
    else:
        print(f"mux-indicator: {label} waiting for the tray watcher",
              flush=True)
    task = asyncio.create_task(_watch(item, argv, label))
    return bus, task, item


async def _supervise():
    """Keep the published set matching the discovered set, forever.

    THE SET IS LIVE NOW, which is the whole point of reading latch's locks
    rather than a config file: latch to a box and its item appears; detach and
    it goes. Nothing is stood up or torn down by hand, and nothing has to be
    edited per machine.

    WITHDRAWING IS DISCONNECTING. A tray host drops an item when its bus name
    goes away, so closing the connection is the withdrawal -- there is no
    "unregister" in the SNI spec. Verified against a live waybar.

    THE BUS NAME INDEX ONLY EVER GOES UP. Reusing the index of a departed host
    would hand a tray host a name it may still be holding state for, and the
    spec's name is meant to be unique per item; a counter costs nothing.
    """
    live = {}          # label -> (bus, task)
    index = 0
    announced = False
    # ONE Slots FOR THE PROCESS, so the in-memory table is the same object
    # every tick. Re-reading the file per pass would work and would also mean a
    # host assigned this tick is invisible to the next one until the write
    # lands, which is a race for nothing.
    _slots = Slots(len(MARK_PALETTE))
    while True:
        try:
            want = {label: argv for label, argv in load_sources(mux_bin=MUX)}
        except Exception as e:
            # Discovery failing must never take the daemon down: the items
            # already published are still telling the truth.
            print(f"mux-indicator: discovery failed: {e}", flush=True)
            await asyncio.sleep(DISCOVER)
            continue

        if not announced or set(want) != set(live):
            _names = ", ".join(sorted(want)) or "none"
            print(f"mux-indicator: watching {_names}", flush=True)
            announced = True

        for label in list(live):
            if label not in want:
                bus, task, _item = live.pop(label)
                task.cancel()
                try:
                    bus.disconnect()
                except Exception:
                    pass
                print(f"mux-indicator: - {label} (latch ended)", flush=True)

        for label, argv in want.items():
            if label in live:
                continue
            index += 1
            try:
                live[label] = await _publish(index, label, argv)
            except Exception as e:
                # One host that cannot be published must not cost the others --
                # and the others are exactly where its absence would show.
                print(f"mux-indicator: could not publish {label}: {e}",
                      flush=True)

        # AFTER publishing, not before: a host joining is the tick that turns
        # the marks ON, and marking only the previously-live items would leave
        # the newcomer blank until the next pass -- the one item you are
        # looking at precisely because it just appeared.
        plan = mark_plan(live, local_label(), _slots)
        for _label, (_b, _t, _item) in live.items():
            _item.set_mark(*plan[_label])
        await asyncio.sleep(DISCOVER)


async def run():
    await _supervise()
