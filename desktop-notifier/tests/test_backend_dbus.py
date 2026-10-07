"""backend_dbus.py: the StatusNotifierItem wire surface, and nothing else.

THIS IS THE ONLY TEST FILE THAT NEEDS dbus_next, which is the property worth
protecting. Everything about WHAT an item shows is asserted in test_sni.py
against `sni.Tile`, so it runs on a machine with no bus; what is left here is
the handful of facts that are true because the SNI spec says so.

IT SKIPS RATHER THAN FAILS where the dependency is absent, because that is the
honest answer on a platform this presenter is not for. The suite's own rule
applies though: a skip is invisible, so the SHARED half must not be in here or
it would quietly stop being tested on exactly the platform we are trying to
support.
"""
import unittest

try:
    import mux_desktop_notifier.backend_dbus as backend
    import mux_desktop_notifier.sni as sni
    HAVE_DBUS = True
except ImportError:                                     # pragma: no cover
    HAVE_DBUS = False


def _item(**kw):
    return backend.Indicator(sni.Tile(label="northwood", **kw))


@unittest.skipUnless(HAVE_DBUS, "dbus_next is not installed")
class Pixmap(unittest.TestCase):
    """What a tray host actually reads to draw the icon."""

    def test_IconPixmap_is_the_current_render(self):
        i = _item()
        self.assertEqual(i.IconPixmap, i._tile.pixmap)
        self.assertTrue(i.IconPixmap, "the item exposed an EMPTY pixmap")

    def test_it_FOLLOWS_a_state_change(self):
        """The property must read the live tile, not a copy taken at
        construction: that would freeze every icon at `none` forever."""
        i = _item()
        before = i.IconPixmap
        i._tile._state, i._tile._count = "blocked", 4
        i._tile._paint()
        self.assertNotEqual(before, i.IconPixmap)

    def test_the_ATTENTION_pixmap_is_the_same_image(self):
        """A host in NeedsAttention reads AttentionIconPixmap instead. Serving
        an empty one there is how a blocked item goes blank at exactly the
        moment it matters most."""
        i = _item(state="blocked", count=2)
        self.assertEqual(i.AttentionIconPixmap, i.IconPixmap)
        self.assertTrue(i.AttentionIconPixmap)

    def test_no_icon_NAME_is_advertised(self):
        """We ship pixmaps, not themed icon names. A non-empty name would make
        a host look for a theme icon that does not exist and draw nothing."""
        i = _item()
        self.assertEqual(i.IconName, "")
        self.assertEqual(i.AttentionIconName, "")
        self.assertEqual(i.OverlayIconName, "")

    def test_the_category_is_ApplicationStatus(self):
        self.assertEqual(_item().Category, "ApplicationStatus")

    def test_it_does_NOT_advertise_a_menu(self):
        """There is no dbusmenu yet, so ItemIsMenu must stay false or a host
        will introspect a Menu property that is not there and left-click will
        stop reaching Activate."""
        self.assertFalse(_item().ItemIsMenu)


@unittest.skipUnless(HAVE_DBUS, "dbus_next is not installed")
class Wiring(unittest.TestCase):
    """The seam itself: a tile's repaint has to reach the bus.

    THE WHOLE COUPLING IS TWO CALLBACKS, so these are the assertions that say
    the split did not quietly disconnect the tray from the thing it draws. A
    tile whose `on_icon` goes nowhere renders perfectly and never repaints,
    which is indistinguishable from a frozen host: the exact failure this
    package exists to make visible.
    """

    def test_a_repaint_emits_NewIcon(self):
        tile = sni.Tile(label="northwood")
        item = backend.Indicator(tile)
        seen = []
        item.NewIcon = lambda: seen.append("icon")
        tile.on_icon = item.NewIcon
        tile._paint()
        self.assertEqual(seen, ["icon"])

    def test_constructing_the_item_wires_the_tile(self):
        """Asserted on the IDENTITY of the callbacks rather than on a repaint,
        because a tile constructed and never wired still paints: it just does
        it into the default no-op."""
        tile = sni.Tile(label="northwood")
        self.assertNotEqual(tile.on_icon, None)
        item = backend.Indicator(tile)
        self.assertEqual(tile.on_icon, item.NewIcon)
        self.assertEqual(tile.on_status, item.NewStatus)

    def test_the_tooltip_keeps_the_SNI_wire_shape(self):
        """`(sa(iiay)ss)`: icon name, icon data, title, body. A host reads the
        TITLE out of index 2, so a shape change silently empties the hover."""
        tip = _item().ToolTip
        self.assertEqual(len(tip), 4)
        self.assertEqual(tip[0], "")
        self.assertEqual(tip[1], [])
        self.assertEqual(tip[2], "mux @ northwood")

    def test_the_handle_closes_the_connection(self):
        """Withdrawing an item IS disconnecting its bus, so the handle the
        supervisor holds must actually do that; it swallows a failure because
        a connection already gone is the normal case on shutdown."""
        class Bus:
            def __init__(self):
                self.gone = False

            def disconnect(self):
                self.gone = True
        b = Bus()
        backend.Handle(b, None).close()
        self.assertTrue(b.gone)

        class Angry:
            def disconnect(self):
                raise RuntimeError("already gone")
        backend.Handle(Angry(), None).close()


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
