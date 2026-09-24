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

from mux_indicator.render import (STATE_BADGE, STATE_FRAME, icon_pixmap,
                                  parse_pair, _prompt, _screen, _to_argb)

try:
    from PIL import Image
except ImportError:                                     # pragma: no cover
    Image = None

STATES = ("blocked", "working", "idle", "none", "unknown")


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


class UnreachableIsNotCalm(unittest.TestCase):
    """`unknown` is a STATE now, and the one rule about it is non-negotiable.

    A source that could not be reached says NOTHING about that host: it may be
    idle, it may have six blocked agents. Before this it fell through to `none`
    and drew a quiet grey tile, asserting the one thing we do not know. A tray
    confidently reporting a machine it cannot see is worse than no tray at all,
    and preventing exactly that is why the cross-machine design pins "empty is
    exit 0" -- so a quiet host and an unreachable one can never collapse into
    one answer.
    """

    def test_unknown_does_not_look_like_none(self):
        self.assertNotEqual(icon_pixmap("unknown", None)[0][2],
                            icon_pixmap("none", None)[0][2])

    def test_unknown_does_not_look_like_idle(self):
        """The other calm glyph, and the more dangerous confusion: idle wears a
        green check, which reads as a positive report about the host."""
        self.assertNotEqual(icon_pixmap("unknown", None)[0][2],
                            icon_pixmap("idle", None)[0][2])

    def test_unknown_has_its_OWN_frame_colour(self):
        """Asserted on the table, not just on the rendered bytes, because the
        two halves of unknown's look cover for each other. Mutation testing
        showed it: delete the frame row and the tile STILL differs from `none`,
        because the badge row alone is enough to make the pixels differ. Two
        properties, one assertion, and neither individually killable -- so each
        gets its own. What matters here is that an unreachable host does not
        wear the agentless colour."""
        self.assertIn("unknown", STATE_FRAME)
        self.assertNotEqual(STATE_FRAME["unknown"], STATE_FRAME["none"])

    def test_unknown_has_a_BADGE_and_none_does_not(self):
        """The other half. `none` deliberately has no badge, so a badge is what
        carries "I have something to say about this host" -- here, a `?`."""
        self.assertIn("unknown", STATE_BADGE)
        self.assertNotIn("none", STATE_BADGE)

    def test_unknown_ignores_a_count(self):
        """There is no count to draw -- that is what unknown MEANS. A number
        here would be a quantity we invented."""
        self.assertEqual(icon_pixmap("unknown", None)[0][2],
                         icon_pixmap("unknown", 4)[0][2])


class UnknownInputIsSurvivable(unittest.TestCase):
    """The state word comes from `mux agent-summary`, soon from a REMOTE one.

    A different mux version, a truncated read, or a host that answers something
    unexpected must not be able to kill the tray daemon. Falling back to the
    `none` look is the right answer: it claims nothing.
    """

    def test_an_UNRECOGNISED_word_renders_as_none(self):
        """Distinct from the `unknown` STATE above, which has its own look. A
        word mux never sends (a newer version, a truncated read) still falls
        back to the claim-nothing glyph rather than raising."""
        self.assertEqual(icon_pixmap("no-such-state", None)[0][2],
                         icon_pixmap("none", None)[0][2])

    def test_unknown_state_with_a_count_does_not_raise(self):
        self.assertTrue(icon_pixmap("no-such-state", 4))

    def test_empty_state_does_not_raise(self):
        self.assertTrue(icon_pixmap("", None))


GREY = "#d0d0d0 #303030"      # what `mux host-color` gives for a greyscale row
CREAM = "#ffffd7 #5f3a1a"     # a deliberately unalike pair


class HostIdentity(unittest.TestCase):
    """The host colour pair, which answers "WHICH machine is this?" at a glance.

    The pair comes from `mux host-color`, so the same rule that paints a host's
    status-bar chip paints its tray item -- otherwise the two disagree about
    which machine is which and neither looks broken. The bg becomes the screen
    and the fg paints the `>_`, which is what each colour is FOR: the pair
    exists so fg is legible on bg, so that legibility comes for free instead of
    being re-derived by a lift heuristic here.

    THE INVARIANT THAT MATTERS MOST is the last test: host colour must never be
    able to make one state look like another. Identity and state are separate
    dimensions -- frame and badge carry state, screen and prompt carry identity
    -- and a change that let them collide would quietly cost the icon its job.
    """

    def test_parses_the_pair(self):
        self.assertEqual(parse_pair(GREY),
                         ((0xD0, 0xD0, 0xD0, 0xFF), (0x30, 0x30, 0x30, 0xFF)))

    def test_a_refusal_is_not_a_colour(self):
        """`mux host-color` exits 1 for colours 0-15 (the terminal's own, which
        every theme remaps, so there is no correct hex) and prints nothing. The
        answer to that is the neutral look, never a guess: a wrong colour on the
        thing whose job is identifying a machine is worse than no colour."""
        for bad in ("", "   ", "#d0d0d0", "nope nope", "#d0d0d0 #30303",
                    "#d0d0d0 303030", "#gggggg #303030",
                    "#d0d0d0 #303030 #extra"):
            self.assertIsNone(parse_pair(bad), f"{bad!r} parsed as a colour")

    def test_two_hosts_do_not_look_alike(self):
        """The whole feature. Two tray items that render identically leave you
        hovering each one to find out which box is which."""
        a = icon_pixmap("idle", None, host=parse_pair(GREY))[0][2]
        b = icon_pixmap("idle", None, host=parse_pair(CREAM))[0][2]
        self.assertNotEqual(a, b)

    def test_a_host_differs_from_the_neutral_look(self):
        """Otherwise the pair is being parsed and then ignored -- which would
        pass every "it renders" check while the feature did nothing."""
        self.assertNotEqual(
            icon_pixmap("idle", None, host=parse_pair(GREY))[0][2],
            icon_pixmap("idle", None)[0][2])

    # THE NEXT TWO ARE SPLIT ON PURPOSE, and the tile-level assertion above is
    # why they have to be. The host pair reaches the glyph through TWO
    # independent places -- the screen takes its bg, the prompt takes its fg --
    # and either one alone is enough to make the whole tile differ from neutral.
    # So a single tile-level check kills NEITHER: delete one and the other still
    # carries it. Measured, not guessed, one commit after the same shape
    # survived a mutation in unknown's frame-vs-badge pair.
    def test_the_SCREEN_takes_the_hosts_background(self):
        """Which is literally what that colour is for: it is the bg of that
        host's status-bar chip."""
        self.assertNotEqual(_screen("idle", parse_pair(GREY)),
                            _screen("idle"))

    def test_the_PROMPT_takes_the_hosts_foreground(self):
        """And exactly the fg, not a lift of it -- the pair exists so fg is
        legible on bg, so pairing them here gets that legibility for free
        instead of re-deriving it and risking a pale host colour."""
        fg, _bg = parse_pair(GREY)
        self.assertEqual(_prompt("idle", parse_pair(GREY)), fg)

    def test_none_host_is_the_historical_look(self):
        """A single-host install must render exactly as it always did, so the
        multi-host work cannot change what one user already sees."""
        self.assertEqual(icon_pixmap("working", 3, host=None),
                         icon_pixmap("working", 3))

    def test_STATE_STILL_READS_UNDER_EVERY_HOST(self):
        """The invariant. Identity tints the screen and the prompt; STATE owns
        the frame and the badge. If a host colour could collapse two states the
        icon would stop answering the question it exists for, and it would do so
        silently -- on one host only, which is the hardest kind to notice."""
        for pair in (GREY, CREAM):
            host = parse_pair(pair)
            seen = {}
            for state in STATES:
                key = bytes(icon_pixmap(state, 2, host=host)[0][2])
                clash = seen.get(key)
                self.assertIsNone(
                    clash, f"under host {pair}, {state} == {clash}")
                seen[key] = state

    def test_unreachable_keeps_its_host_colour(self):
        """`unknown` still has to say WHICH host is unreachable -- that is the
        one moment identity matters most. It also stays distinct from the
        reachable states on the same host."""
        host = parse_pair(GREY)
        unk = icon_pixmap("unknown", None, host=host)[0][2]
        self.assertNotEqual(unk, icon_pixmap("unknown", None)[0][2])
        self.assertNotEqual(unk, icon_pixmap("idle", None, host=host)[0][2])


class Deterministic(unittest.TestCase):
    def test_same_input_same_bytes(self):
        """No clock, no randomness. A repaint must not flicker the picture."""
        self.assertEqual(icon_pixmap("blocked", 2), icon_pixmap("blocked", 2))


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
