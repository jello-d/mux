"""The StatusNotifierItem D-Bus service (org.kde.StatusNotifierItem).

Walking skeleton: exports one item with a single static, owned-drawn glyph and
registers it with the live StatusNotifierWatcher (waybar's tray, or any DE's).
State-reading, the count badge, activate->next-blocked, and the menu come next;
this proves the D-Bus + pixmap path end to end first.
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


class Indicator(ServiceInterface):
    def __init__(self, state="blocked"):
        super().__init__("org.kde.StatusNotifierItem")
        self._state = state
        self._pixmap = icon_pixmap(state)

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
        # blocked -> NeedsAttention (a host may emphasise it); else Active.
        return "NeedsAttention" if self._state == "blocked" else "Active"

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
        return ["", [], "mux", "walking skeleton: a static indicator"]

    @dbus_property(access=PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        # No dbusmenu yet -> left-click Activate is the whole interaction. The
        # per-session menu (com.canonical.dbusmenu) is a later feature; until
        # then we advertise no Menu property so a host doesn't introspect one.
        return False

    @method()
    def Activate(self, x: "i", y: "i"):
        print(f"mux-indicator: Activate at {x},{y}")

    @method()
    def SecondaryActivate(self, x: "i", y: "i"):
        print(f"mux-indicator: SecondaryActivate at {x},{y}")

    @method()
    def Scroll(self, delta: "i", orientation: "s"):
        print(f"mux-indicator: Scroll {delta} {orientation}")

    @signal()
    def NewIcon(self):
        pass

    @signal()
    def NewStatus(self, status) -> "s":
        return status


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
    print(f"mux-indicator: registered {name}", flush=True)
    await asyncio.get_event_loop().create_future()  # run until killed
