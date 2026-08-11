"""The StatusNotifierItem D-Bus service (org.kde.StatusNotifierItem).

Exports one tray item and updates it live: on a state/count change it re-renders
the owned pixmap and emits NewIcon/NewStatus so the host (waybar's tray, or any
DE's) repaints. State comes from `mux agent-summary` (the aggregate worst state
+ count across the namespace's sessions), polled on a timer. A manual override
file takes precedence when present, for testing without live sessions.
"""
import asyncio
import os

from dbus_next import BusType, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

from .render import icon_pixmap

WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
# State feed. MUX runs `mux agent-summary` ("<state> <count>") as the live
# source, polled every POLL seconds. CTL is an OPT-IN manual override file for
# testing: set MUX_INDICATOR_CTL to a path and write "<state> <count>" into it
# to force a value. UNSET by default -- so the deployed service reads ONLY the
# live feed and no stray /tmp file can silently pin it.
MUX = os.environ.get("MUX_BIN", "mux")
POLL = float(os.environ.get("MUX_INDICATOR_POLL", "1.5"))
CTL = os.environ.get("MUX_INDICATOR_CTL")
# On a state/count change the `_` cursor blinks BLINK_N times at BLINK_MS each,
# to catch the eye, then settles cursor-on.
BLINK_N = int(os.environ.get("MUX_INDICATOR_BLINK", "3"))
BLINK_MS = int(os.environ.get("MUX_INDICATOR_BLINK_MS", "140"))


class Indicator(ServiceInterface):
    def __init__(self, state="none", count=None):
        super().__init__("org.kde.StatusNotifierItem")
        self._state = state
        self._count = count
        self._pixmap = icon_pixmap(state, count)
        self._blink = None

    def _status(self):
        return "NeedsAttention" if self._state == "blocked" else "Active"

    def _paint(self, cursor=True):
        self._pixmap = icon_pixmap(self._state, self._count, cursor=cursor)
        self.NewIcon()

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
        return "mux-indicator"

    @dbus_property(access=PropertyAccess.READ)
    def Title(self) -> "s":
        return "mux"

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
        if self._count is None:
            body = "all sessions idle"
        else:
            body = f"{self._count} session(s): {self._state}"
        return ["", [], "mux", body]

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
        return _parse(open(CTL).read())
    except OSError:
        return None


async def _query_mux():
    """`mux agent-summary` -> (state, count), or None if it can't be run."""
    try:
        proc = await asyncio.create_subprocess_exec(
            MUX, "agent-summary",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL)
        out, _ = await proc.communicate()
    except OSError:
        return None
    return _parse(out.decode("utf-8", "replace"))


async def _watch(item):
    """Feed the icon: the override file if present, else `mux agent-summary`.
    Only repaints when the (state, count) actually changes."""
    last = None
    while True:
        cur = _read_override() or await _query_mux()
        if cur is not None and cur != last:
            last = cur
            item.set(*cur)
            print(f"mux-indicator: set {cur[0]} {cur[1]}", flush=True)
        await asyncio.sleep(POLL)


async def run():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    item = Indicator()
    bus.export(ITEM_PATH, item)
    name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
    await bus.request_name(name)

    async def register():
        try:
            intro = await bus.introspect(WATCHER, WATCHER_PATH)
            obj = bus.get_proxy_object(WATCHER, WATCHER_PATH, intro)
            w = obj.get_interface(WATCHER)
            await w.call_register_status_notifier_item(name)
            print(f"mux-indicator: registered {name} "
                  f"(feed: {MUX} agent-summary)", flush=True)
        except Exception as e:
            print(f"mux-indicator: register failed: {e}", flush=True)

    # (Re)register whenever the tray watcher (waybar) appears, so a `wb restart`
    # or a late-starting bar never leaves us invisible.
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
        print("mux-indicator: waiting for the tray watcher", flush=True)
    asyncio.create_task(_watch(item))
    await asyncio.get_event_loop().create_future()  # run until killed
