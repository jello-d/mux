"""The D-Bus presenter: StatusNotifierItem, and the connections it needs.

THE ONLY FILE IN THIS PACKAGE THAT IMPORTS dbus_next. That is the whole
contract, and it is what makes a second platform an ADDITION rather than a
fork: every decision about what a tray item should SHOW lives in `sni.Tile`
and the supervisor around it, both of which import on a machine with no bus at
all. Measured before the split: with dbus_next absent, 147 of this package's
289 tests errored, because the only way to reach any of those decisions was to
construct a `ServiceInterface` subclass.

SO A MAC NEEDS A SIBLING OF THIS FILE AND NOTHING ELSE TOUCHED. It has to
supply the same three things the supervisor asks for, below; `render` already
owns every pixel and `sources` every transport.

N ITEMS FROM ONE PROCESS, AND IT HAS TO BE A CONNECTION EACH. A single
connection can own several bus names, but `RegisterStatusNotifierItem` takes a
service NAME and nothing else (the watcher then looks for /StatusNotifierItem
on it), so two names on one connection resolve to the same exported object and
you get the same item twice. Measured against a live waybar: two connections
from one pid registered as two items and drew as two. The `-1` in
`org.kde.StatusNotifierItem-<pid>-1` is a per-process item INDEX, so the
naming convention anticipated exactly this.
"""
import asyncio
import os

from dbus_next import BusType, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

from .sni import (ITEM_PATH, Toaster, WATCHER, WATCHER_PATH, item_bus_name,
                  item_id, wants_reregister)

# Named so a supervisor can say which presenter it got, in a log line a human
# reads before they know anything else about the process.
NAME = "dbus"


class Indicator(ServiceInterface):
    """org.kde.StatusNotifierItem over one `Tile`.

    A THIN WRAPPER ON PURPOSE: every method here either reads the tile or
    forwards a signal. Nothing decides anything, because deciding is what the
    tile is for and a decision taken here would be one a Mac could not reach.
    """

    def __init__(self, tile):
        super().__init__("org.kde.StatusNotifierItem")
        self._tile = tile
        # The tray host learns about a repaint through these two signals, so
        # the tile is handed them as its callbacks and never knows what they
        # are. This is the entire coupling between a decision and a bus.
        tile.on_icon = self.NewIcon
        tile.on_status = self.NewStatus

    # `_label`/`_local` are read straight off the tile rather than copied: a
    # second copy of an identity is how a tray item starts disagreeing with
    # the thing it speaks for.
    @property
    def _label(self):
        return self._tile.label

    @dbus_property(access=PropertyAccess.READ)
    def Category(self) -> "s":
        return "ApplicationStatus"

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> "s":
        return self._tile.ident()

    @dbus_property(access=PropertyAccess.READ)
    def Title(self) -> "s":
        return self._tile.title()

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> "s":
        return self._tile.status()

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def IconPixmap(self) -> "a(iiay)":
        return self._tile.pixmap

    @dbus_property(access=PropertyAccess.READ)
    def OverlayIconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def AttentionIconName(self) -> "s":
        return ""

    @dbus_property(access=PropertyAccess.READ)
    def AttentionIconPixmap(self) -> "a(iiay)":
        return self._tile.pixmap

    @dbus_property(access=PropertyAccess.READ)
    def ToolTip(self) -> "(sa(iiay)ss)":
        title, body = self._tile.tooltip()
        return ["", [], title, body]

    @dbus_property(access=PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        # No dbusmenu yet -> left-click Activate is the whole interaction. The
        # per-session menu (com.canonical.dbusmenu) is a later feature; until
        # then we advertise no Menu property so a host doesn't introspect one.
        return False

    @method()
    def Activate(self, x: "i", y: "i"):
        """Left click: jump that host to whatever has been waiting longest.

        FIRE AND FORGET. Activate is a D-Bus method and the tray host is
        waiting on it, so anything that touches the network has to be handed
        to the loop rather than awaited here: an unreachable box would
        otherwise hang the bar, which is precisely the failure this whole
        feature exists to make visible.
        """
        print(f"mux-desktop-notifier: activate "
              f"{self._label or 'local'}", flush=True)
        if self._on_activate is not None:
            asyncio.ensure_future(self._on_activate(self._label))

    @method()
    def SecondaryActivate(self, x: "i", y: "i"):
        print(f"mux-desktop-notifier: SecondaryActivate at {x},{y}", flush=True)

    @method()
    def Scroll(self, delta: "i", orientation: "s"):
        print(f"mux-desktop-notifier: Scroll {delta} {orientation}", flush=True)

    @signal()
    def NewIcon(self):
        pass

    @signal()
    def NewStatus(self, status) -> "s":
        return status


# The click handler, set by `export`. A CLASS ATTRIBUTE rather than a
# constructor argument because dbus_next introspects __init__'s annotations to
# build the interface, so an extra parameter there is a change to the exported
# shape rather than to this object.
Indicator._on_activate = None


class Handle:
    """What the supervisor holds for one published item.

    WITHDRAWING IS DISCONNECTING. A tray host drops an item when its bus name
    goes away, so closing the connection IS the withdrawal: there is no
    "unregister" in the SNI spec. Verified against a live waybar. A macOS
    handle will mean something else entirely, which is why the supervisor only
    ever calls `close()`.
    """

    def __init__(self, bus, item):
        self.bus = bus
        self.item = item

    def close(self):
        try:
            self.bus.disconnect()
        except Exception:
            pass


async def session_bus():
    """One connection to the session bus."""
    return await MessageBus(bus_type=BusType.SESSION).connect()


def toaster(bus, enabled=True):
    """The freedesktop notification presenter over `bus`.

    `Toaster` itself lives beside the supervisor because it is duck-typed on a
    bus object and so carries no import dependency, which is what lets its
    four withdrawal rules be asserted against a fake bus on a platform that
    has none. What is D-Bus-specific is choosing it, and that happens here.
    """
    return Toaster(bus, enabled=enabled)


async def export(index, tile, activate=None):
    """Publish one tile: a connection, a bus name, an exported object, and a
    (re)registration with whatever tray watcher is or becomes present.

    The bus name index is 1-based to match the convention every other SNI
    producer uses.
    """
    bus = await session_bus()
    item = Indicator(tile)
    if activate is not None:
        item._on_activate = activate
    bus.export(ITEM_PATH, item)
    name = item_bus_name(os.getpid(), index)
    await bus.request_name(name)
    label = tile.label

    async def register():
        try:
            intro = await bus.introspect(WATCHER, WATCHER_PATH)
            obj = bus.get_proxy_object(WATCHER, WATCHER_PATH, intro)
            w = obj.get_interface(WATCHER)
            await w.call_register_status_notifier_item(name)
            print(f"mux-desktop-notifier: + {label} ({name})", flush=True)
        except Exception as e:
            print(f"mux-desktop-notifier: register failed for {label}: {e}",
                  flush=True)

    # (Re)register whenever the tray watcher (waybar) appears, so a `wb
    # restart` or a late-starting bar never leaves us invisible. Per
    # connection, because each name has to re-announce itself.
    di = await bus.introspect("org.freedesktop.DBus", "/org/freedesktop/DBus")
    dobj = bus.get_proxy_object("org.freedesktop.DBus",
                                "/org/freedesktop/DBus", di)
    dbus = dobj.get_interface("org.freedesktop.DBus")

    def on_owner(n, old, new):
        if wants_reregister(n, new):
            asyncio.get_event_loop().create_task(register())
    dbus.on_name_owner_changed(on_owner)

    try:
        owner = await dbus.call_get_name_owner(WATCHER)
    except Exception:
        owner = ""
    if owner:
        await register()
    else:
        print(f"mux-desktop-notifier: {label} waiting for the tray watcher",
              flush=True)
    return Handle(bus, item)
