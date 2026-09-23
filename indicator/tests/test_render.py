"""render.py -- the owned tray glyphs, which had no test at all.

render.py is the ONLY place the indicator's visual identity lives, and every
mistake it can make is a QUIET one: the tray shows a picture, nobody diffs a
picture, and a wrong picture looks exactly as confident as a right one. So the
properties asserted here are the ones a human would not notice going wrong.

The three that matter most:

  THE BYTE ORDER. IconPixmap is ARGB32 in NETWORK (big-endian) order per the
  StatusNotifierItem spec, and PIL hands out RGBA. Getting that permutation
  wrong does not crash -- it silently swaps the channels, so the icon renders in
  believable but wrong colours, and on some hosts the alpha lands in a colour
  channel and the whole tile goes opaque black.

  THE STATES MUST DIFFER. The entire point of the icon is that `blocked` does
  not look like `idle`. A refactor that collapsed two states to the same pixels
  would pass every structural check and destroy the feature.

  IT MUST NOT RAISE on a state it has never heard of. The state comes from
  `mux agent-summary` -- soon from a REMOTE one, over ssh, possibly a different
  version. An unknown word must fall back, not take the daemon down.
"""
import unittest

from mux_indicator.render import icon_pixmap, _to_argb

try:
    from PIL import Image
except ImportError:                                     # pragma: no cover
    Image = None

STATES = ("blocked", "working", "idle", "none")


class ByteOrder(unittest.TestCase):
    def test_argb_network_order(self):
        """A -> R -> G -> B, which is NOT the RGBA PIL gives us.

        Asserted on a single known pixel rather than on a rendered tile, so the
        failure says "the permutation is wrong" instead of "some bytes differ".
        """
        img = Image.new("RGBA", (1, 1), (0x11, 0x22, 0x33, 0x44))
        self.assertEqual(_to_argb(img), bytes([0x44, 0x11, 0x22, 0x33]))

    def test_argb_length_is_four_bytes_per_pixel(self):
        img = Image.new("RGBA", (3, 2), (1, 2, 3, 4))
        self.assertEqual(len(_to_argb(img)), 3 * 2 * 4)


class Shape(unittest.TestCase):
    def test_entries_are_size_size_and_a_full_buffer(self):
        """Each entry is [w, h, argb] with exactly w*h*4 bytes.

        A short buffer is the failure that makes a tray host draw garbage or
        drop the item silently, and it is invisible from this side.
        """
        for state in STATES:
            for w, h, buf in icon_pixmap(state, 3):
                self.assertEqual(w, h, "tiles are square")
                self.assertEqual(len(buf), w * h * 4,
                                 f"{state}: buffer is not w*h*4")

    def test_requested_sizes_are_the_sizes_returned(self):
        got = [(w, h) for w, h, _ in icon_pixmap("idle", None, sizes=(16, 64))]
        self.assertEqual(got, [(16, 16), (64, 64)])

    def test_default_offers_several_sizes(self):
        """Hosts pick a size; offering one means the rest get scaled."""
        self.assertGreater(len(icon_pixmap("idle", None)), 1)


class StatesAreDistinct(unittest.TestCase):
    def test_no_two_states_render_alike(self):
        """blocked must not look like idle. This is the whole feature."""
        seen = {}
        for state in STATES:
            key = bytes(icon_pixmap(state, 2)[0][2])
            clash = seen.get(key)
            self.assertIsNone(
                clash, f"{state} renders identically to {clash}")
            seen[key] = state

    def test_count_changes_the_picture(self):
        """The badge carries the number; if it did not, 1 and 9 would agree."""
        for state in ("blocked", "working"):
            one = icon_pixmap(state, 1)[0][2]
            nine = icon_pixmap(state, 9)[0][2]
            self.assertNotEqual(one, nine, f"{state}: count is not drawn")

    def test_cursor_frame_differs(self):
        """The blink needs two frames. If they matched, it would not blink."""
        on = icon_pixmap("working", 1, cursor=True)[0][2]
        off = icon_pixmap("working", 1, cursor=False)[0][2]
        self.assertNotEqual(on, off)


class CountIsIgnoredWhereItShouldBe(unittest.TestCase):
    """idle draws a check and none draws no badge, so neither shows a number.

    Pinned because the natural refactor -- "just always draw the count" -- is
    invisible in code review and produces a tray icon claiming `idle 4`, which
    reads as four things needing attention when the truth is the opposite.
    """

    def test_idle_ignores_count(self):
        self.assertEqual(icon_pixmap("idle", None)[0][2],
                         icon_pixmap("idle", 7)[0][2])

    def test_none_ignores_count(self):
        self.assertEqual(icon_pixmap("none", None)[0][2],
                         icon_pixmap("none", 7)[0][2])

    def test_count_still_matters_for_a_loud_state(self):
        """The mirror of the idle case, and together they pin the wiring.

        idle looks the same with or without a count (keyed on STATE), while
        blocked does not (keyed on its count). If check-vs-number were keyed on
        `count is None` -- as it was -- then blocked WITH NO COUNT would draw
        idle's check: the calmest glyph there is, on the loudest state. `_parse`
        yields None for a `-` or non-numeric count, so that was reachable.
        """
        self.assertNotEqual(icon_pixmap("blocked", None)[0][2],
                            icon_pixmap("blocked", 1)[0][2])

    def test_a_loud_state_without_a_count_still_shows_its_badge(self):
        """Bare, but present: the state is still worth seeing."""
        self.assertNotEqual(icon_pixmap("blocked", None)[0][2],
                            icon_pixmap("none", None)[0][2])


class UnknownInputIsSurvivable(unittest.TestCase):
    """The state word comes from `mux agent-summary`, soon from a REMOTE one.

    A different mux version, a truncated read, or a host that answers something
    unexpected must not be able to kill the tray daemon. Falling back to the
    `none` look is the right answer: it claims nothing.
    """

    def test_unknown_state_renders_as_none(self):
        self.assertEqual(icon_pixmap("no-such-state", None)[0][2],
                         icon_pixmap("none", None)[0][2])

    def test_unknown_state_with_a_count_does_not_raise(self):
        self.assertTrue(icon_pixmap("no-such-state", 4))

    def test_empty_state_does_not_raise(self):
        self.assertTrue(icon_pixmap("", None))


class Deterministic(unittest.TestCase):
    def test_same_input_same_bytes(self):
        """No clock, no randomness. A repaint must not flicker the picture."""
        self.assertEqual(icon_pixmap("blocked", 2), icon_pixmap("blocked", 2))


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
