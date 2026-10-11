"""The macOS presenter: an NSStatusItem in the menu bar, and banners through
UNUserNotificationCenter.

THE SIBLING OF backend_dbus, not a fork of sni.py. It owes the supervisor
exactly three things and nothing else: `session_bus()`, `toaster(bus, enabled)`
and `export(index, tile, activate) -> handle`. Every decision about WHAT an
item shows stays above that line and is shared, which is the property the
backend split was done for.

WHAT IS MEASURED AND WHAT IS NOT, stated here rather than implied, because
this file was written against a CI runner and not against a desktop. The
runner answered (test/macos-probe, three runs, 2026-10-10):

    NSStatusItem publishes AND DRAWS     1057 px at (645,8)-(866,22)
    NSRunLoop pumped from a coroutine    40 pumps / 40 independent ticks
    PyObjC Cocoa + UserNotifications     pip installs both
    UNUserNotificationCenter resolves    yes, for an ad-hoc signed bundle
    a LaunchAgent in gui/<uid>           bootstraps and runs

    UN AUTHORIZATION                     DENIED, "Notifications are not
                                         allowed for this application"

So the tray half is verified end to end and the banner half is verified only
as far as a machine with no human can take it: the calls are reachable and a
withdrawal leaves zero pending, and whether a banner DRAWS needs a
notification permission somebody granted. That is the one thing left for a
real desktop, and it is why nothing here reports success for a banner it
cannot see.

THE BUNDLE IDENTITY IS A KNOWN LIMIT, measured the same way: a Python process
reports `org.python.python` to NSBundle, because NSBundle resolves from the
PROCESS IMAGE and an interpreter lives in its own framework. A shell shim
inside a .app does not move it. So notification permission for this daemon is
granted to Python generally unless the package is ever shipped as a bundle
with an embedded interpreter, which is a packaging decision rather than a
code one and is not made here.

AND THIS MODULE IMPORTS ON ANY PLATFORM, which is deliberate and is the
lesson the backend split already paid for: 147 of 289 tests used to error with
dbus_next absent, because every decision about what an item shows was reachable
only by constructing a ServiceInterface subclass. `AppKitToaster`'s two
overrides are DECISIONS (reuse the identifier so UN replaces rather than
stacks; withdraw from both the delivered and the pending list), so locking them
behind `import AppKit` would make the same mistake one platform over. Every
AppKit import is therefore inside the function that needs it, and only
`export` and `_pump` are unreachable off a Mac.
"""

import asyncio
import io

from .sni import Toaster

# THE MENU BAR IS ~22 POINTS, so the image is RENDERED at 2x and then told it
# is 22 points tall: on a retina panel that is a crisp tile and on a 1x one
# the downscale is still better than rendering small. `render.tile` owns every
# pixel either way, which is what keeps this file from having an opinion about
# what mux looks like.
BAR_POINTS = 22
BAR_PIXELS = BAR_POINTS * 2

# HOW OFTEN APPKIT IS SERVICED. The probe drove 10ms slices and both the pump
# and an independent asyncio task reached all 40 of their ticks, so this is
# the measured shape rather than a guess. A longer slice blocks the event loop
# for that long, which on a tray costs a late repaint and nothing worse.
PUMP_SLICE = 0.01

_PUMP = None


def _ids():
    """Identifiers for banners we have not raised before.

    ONLY FOR A FIRST RAISE. A replacement reuses the id the map already
    holds, which is what makes UN replace rather than stack, so this is
    reached once per session rather than once per banner.
    """
    n = 0
    while True:
        n += 1
        yield n


_COUNTER = _ids()


def _nsimage(img):
    """A Pillow image as an NSImage, through PNG bytes.

    PNG RATHER THAN A RAW BUFFER, deliberately: NSImage reads it directly, so
    there is no stride, premultiplication or colour-space argument to get
    wrong, and this is a handful of times per state change rather than a hot
    path. backend_dbus packs ARGB for the same pixels because SNI's `a(iiay)`
    demands it; neither conversion belongs in render.py.
    """
    import AppKit
    from Foundation import NSData

    buf = io.BytesIO()
    img.save(buf, "PNG")
    raw = buf.getvalue()
    data = NSData.dataWithBytes_length_(raw, len(raw))
    out = AppKit.NSImage.alloc().initWithData_(data)
    if out is not None:
        out.setSize_(AppKit.NSMakeSize(BAR_POINTS, BAR_POINTS))
        # NOT a template image: a template is recoloured to the bar's
        # appearance and would throw away the state colour, which is the
        # whole signal the tile carries.
        out.setTemplate_(False)
    return out


_CLICKED = None


def _clicked_class():
    """The ObjC class that receives a status item's click, defined on demand.

    DEFINED IN A FUNCTION rather than at module level, because subclassing
    NSObject IS the import: a `class X(NSObject)` at the top would make this
    file unimportable on Linux and take `AppKitToaster`'s testable decisions
    with it. Cached, since registering the same ObjC class name twice raises.

    IT EXISTS ONLY BECAUSE A SELECTOR CANNOT BE A CLOSURE. AppKit sends an
    action to an object, so a Python callable needs something to live on.
    """
    global _CLICKED
    if _CLICKED is not None:
        return _CLICKED

    import objc
    from Foundation import NSObject

    class _Clicked(NSObject):
        def initWithHandler_(self, handler):
            self = objc.super(_Clicked, self).init()
            if self is None:
                return None
            self._handler = handler
            return self

        def clicked_(self, _sender):
            try:
                self._handler()
            except Exception as e:                              # noqa: BLE001
                # SAID, never raised: this runs inside AppKit's own dispatch,
                # so an exception escaping here would be reported by the run
                # loop rather than by us, if at all.
                print(f"mux-desktop-notifier: activate failed: {e}",
                      flush=True)

    _CLICKED = _Clicked
    return _CLICKED


async def _pump():
    """Service AppKit forever from the asyncio loop.

    WHY THIS WORKS AT ALL, and it is the question the notes recorded as
    needing a Mac: an NSRunLoop pumped with a short deadline returns to the
    caller, so `await` between slices lets asyncio run. Measured on the
    runner at 40 pumps against 40 independent ticks of a separate task, both
    complete, neither starved.

    THE ALTERNATIVE IS NOT TAKEN: AppKit could own the main thread and drive
    asyncio from a CFRunLoop observer instead. That is the more conventional
    shape for an app and the wrong one here, because `_supervise` and every
    feed are already asyncio and inverting the ownership would put the whole
    supervisor behind a second scheduler.
    """
    from Foundation import NSDate, NSRunLoop

    loop = NSRunLoop.currentRunLoop()
    while True:
        loop.runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(PUMP_SLICE))
        await asyncio.sleep(0)


def _ensure_pump():
    """One pump per process, started on the first export.

    NOT AT IMPORT, because importing a backend must not need a running event
    loop: `_backend()` is called from a plain function and the supervisor
    decides when there is a loop to attach to.
    """
    global _PUMP
    if _PUMP is None or _PUMP.done():
        _PUMP = asyncio.ensure_future(_pump())
    return _PUMP


class Handle:
    """What the supervisor holds for one published item.

    WITHDRAWING IS REMOVING THE ITEM, where the D-Bus handle disconnects a
    bus: SNI drops an item when its name goes away and a menu bar drops one
    when NSStatusBar is told to. Different mechanisms, which is exactly why
    the supervisor only ever calls `close()`.
    """

    def __init__(self, item, target=None):
        self.item = item
        # HELD DELIBERATELY. AppKit does not retain an action target, so
        # letting this be collected would make the click stop working some
        # time later, which is the hardest kind of bug to attribute.
        self.target = target

    def close(self):
        try:
            import AppKit
            AppKit.NSStatusBar.systemStatusBar().removeStatusItem_(self.item)
        except Exception:
            pass


class AppKitToaster(Toaster):
    """Banners through UNUserNotificationCenter.

    IT INHERITS EVERYTHING THAT IS A DECISION: the wording and the
    host-in-the-title rule, the hook seam with its six fallback paths, the id
    map, and the four rules about when a banner stops being true. Only two
    methods here are platform-specific, which is what `_raise` and `_close`
    were extracted for. A standalone macOS toaster would have been a second
    opinion about when to withdraw, and these notes already record what two
    opinions about one fact cost.

    AN IDENTIFIER IS A STRING HERE, where freedesktop answers a uint32.
    Nothing above cares: the map stores whatever `_raise` returns and only
    `_close` reads it. Replacing is free as a result, because UN replaces a
    delivered banner carrying the same identifier.
    """

    async def _raise(self, prev, summary, body):
        import UserNotifications as UN
        centre = self._bus
        if centre is None:
            raise RuntimeError("no UNUserNotificationCenter")
        # THE PREVIOUS IDENTIFIER IS REUSED, which is how UN replaces rather
        # than stacks. A fresh one per raise would be the column of banners
        # the dbus path avoids by passing its previous id to Notify.
        ident = prev[0] if prev else "mux-%d" % next(_COUNTER)
        content = UN.UNMutableNotificationContent.alloc().init()
        content.setTitle_(summary)
        content.setBody_(body)
        req = UN.UNNotificationRequest.requestWithIdentifier_content_trigger_(
            ident, content, None)
        await _completed(
            lambda done: centre.addNotificationRequest_withCompletionHandler_(
                req, done))
        return ident

    async def _close(self, held):
        centre = self._bus
        if centre is None:
            return
        ident = [held[0]]
        # BOTH LISTS, because a banner may be delivered or still pending and
        # the caller cannot know which: withdrawing one of the two would
        # leave the other to arrive after the thing it announces is over.
        centre.removeDeliveredNotificationsWithIdentifiers_(ident)
        centre.removePendingNotificationRequestsWithIdentifiers_(ident)


async def _completed(call):
    """Run an AppKit call that answers through a completion handler, and wait.

    THE SYSTEM'S OWN ANSWER, not merely that the call returned. Measured on
    the runner: `addNotificationRequest` with a NIL handler reports nothing,
    so a probe that passed nil printed "accepted" while the system was
    refusing the request outright. The error is the interesting half here,
    since an unauthorized daemon is the common case until somebody grants a
    permission.
    """
    loop = asyncio.get_event_loop()
    fut = loop.create_future()

    def done(err):
        if not fut.done():
            loop.call_soon_threadsafe(fut.set_result, err)

    call(done)
    err = await fut
    if err is not None:
        raise RuntimeError(str(err))


async def session_bus():
    """WHAT THE TOASTER NEEDS, which on macOS is not a bus at all.

    The notification centre is a process-wide singleton reachable with no
    connection to anything, so this is where the shape of the two platforms
    differs most and where the seam earns its keep: the supervisor asks for
    "whatever the toaster needs" and never learns what it is.

    None IS A REAL ANSWER. A daemon with no usable notification centre still
    has a working tray, which is the persistent half of this signal, so this
    refuses to make the whole presenter unavailable over it.
    """
    try:
        import UserNotifications as UN
        return UN.UNUserNotificationCenter.currentNotificationCenter()
    except Exception as e:                                      # noqa: BLE001
        print(f"mux-desktop-notifier: no notification centre: {e}",
              flush=True)
        return None


def toaster(bus, enabled=True):
    """The macOS notification presenter over `bus`, which is a UN centre."""
    return AppKitToaster(bus, enabled=enabled)


async def export(index, tile, activate=None):
    """Publish one tile as a menu bar item.

    `index` IS UNUSED AND THAT IS NOT AN OVERSIGHT: it exists because an SNI
    bus name needs a per-process item index, and a menu bar has no such
    namespace. Kept in the signature because the supervisor calls both
    backends identically, and dropping it there would make one platform's
    call shape leak into the shared half.
    """
    import AppKit

    _ensure_pump()
    app = AppKit.NSApplication.sharedApplication()
    # ACCESSORY: no Dock tile and no window, which is what a tray daemon is.
    # Set per export rather than once, because it is idempotent and doing it
    # here means a caller cannot forget it.
    app.setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyAccessory)

    bar = AppKit.NSStatusBar.systemStatusBar()
    item = bar.statusItemWithLength_(AppKit.NSVariableStatusItemLength)
    if item is None:
        raise RuntimeError("the menu bar refused a status item")

    target = None
    button = item.button()
    if button is not None and activate is not None:
        target = _clicked_class().alloc().initWithHandler_(activate)
        button.setTarget_(target)
        button.setAction_("clicked:")

    def repaint():
        img = _nsimage(tile.image(BAR_PIXELS))
        if img is None:
            return
        if button is not None:
            button.setImage_(img)
        else:
            item.setImage_(img)

    # THE TWO CALLBACKS ARE THE WHOLE SEAM, exactly as on the other platform.
    # A status item has no "status" to set, so `on_status` is where the two
    # presenters genuinely differ: SNI tells the host NeedsAttention and a
    # menu bar has nowhere to put that, so the tile's own colour carries it
    # and this is a no-op rather than a lie about an unsupported feature.
    tile.on_icon = repaint
    tile.on_status = lambda _s: None
    repaint()

    item.setToolTip_("%s\n%s" % tile.tooltip())
    print(f"mux-desktop-notifier: + {tile.label or 'local'} (menu bar)",
          flush=True)
    return Handle(item, target)
