"""The StatusNotifierItem D-Bus service (org.kde.StatusNotifierItem).

Exports one tray item and updates it live: on a state/count change it re-renders
the owned pixmap and emits NewIcon/NewStatus so the host (waybar's tray, or any
DE's) repaints. State currently comes from a small control file (poke it for
testing); the real feed -- `mux agent-summary` -- replaces that source later.
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
# Interim state source: a control file "<state> <count>" (count '-'/'idle' ->
# the all-idle check). Fixed path so a poke script always finds it.
CTL = "/tmp/mux-indicator.ctl"


class Indicator(ServiceInterface):
    def __init__(self, state="blocked", count=2):
        super().__init__("org.kde.StatusNotifierItem")
        self._state = state
        self._count = count
        self._pixmap = icon_pixmap(state, count)

    def _status(self):
        return "NeedsAttention" if self._state == "blocked" else "Active"

    def set(self, state, count):
        """Update the icon live: re-render, then tell the host to repaint."""
        self._state, self._count = state, count
        self._pixmap = icon_pixmap(state, count)
        self.NewIcon()
        self.NewStatus(self._status())

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


async def _watch(item, path):
    """Poll the control file; on change, set() from '<state> <count>'."""
    last = None
    while True:
        try:
            mt = os.stat(path).st_mtime
        except OSError:
            mt = None
        if mt is not None and mt != last:
            last = mt
            try:
                parts = open(path).read().split()
                state = parts[0]
                raw = parts[1] if len(parts) > 1 else "-"
                idle = raw in ("-", "idle", "none", "check")
                item.set(state, None if idle else int(raw))
                print(f"mux-indicator: set {state} {raw}", flush=True)
            except Exception as e:
                print(f"mux-indicator: bad poke: {e}", flush=True)
        await asyncio.sleep(0.25)


async def run():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    item = Indicator()
    bus.export(ITEM_PATH, item)
    name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
    await bus.request_name(name)
    intro = await bus.introspect(WATCHER, WATCHER_PATH)
    obj = bus.get_proxy_object(WATCHER, WATCHER_PATH, intro)
    watcher = obj.get_interface(WATCHER)
    await watcher.call_register_status_notifier_item(name)
    print(f"mux-indicator: registered {name} (poke {CTL})", flush=True)
    asyncio.create_task(_watch(item, CTL))
    await asyncio.get_event_loop().create_future()  # run until killed
