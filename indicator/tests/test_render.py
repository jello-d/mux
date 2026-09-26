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

from mux_indicator.render import (MARK_LOCAL_INK, MARK_PALETTE,
                                  STATE_BADGE, STATE_FRAME, mark_ink,
                                  host_mark, icon_pixmap, parse_pair,
                                  _prompt, _screen, _to_argb)

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


class HostMark(unittest.TestCase):
    """The three-character mark, which is what actually makes two hosts tell
    apart. COLOUR CANNOT DO IT: mux derives one of eight pairs by hashing, and
    with only three machines `manifestor` and `manifold` already collide. No
    wider palette fixes that either -- the birthday paradox beats you long
    before the colours run out -- so identity needs a channel that is not a hue.
    """

    def test_the_tail_is_what_distinguishes(self):
        """Fleets share PREFIXES, so the first letters are exactly the ones
        that do not separate. `manifold` and `manifestor` agree for five
        characters; their consonant tails do not."""
        self.assertEqual(host_mark("manifold"), "MLD")
        self.assertEqual(host_mark("manifestor"), "MTR")
        self.assertNotEqual(host_mark("manifold"), host_mark("manifestor"))

    def test_the_first_character_is_kept(self):
        """Even when it is a vowel, so `us-east-1a` still reads as a us-* box
        rather than starting at some consonant in the middle."""
        self.assertTrue(host_mark("us-east-1a").startswith("U"))
        self.assertTrue(host_mark("rover").startswith("R"))

    def test_short_and_vowel_heavy_names_degrade_sanely(self):
        for name, want in (("rover", "RVR"), ("web-01", "W01"), ("a", "A")):
            self.assertEqual(host_mark(name), want)

    def test_no_name_is_no_mark(self):
        """Not a crash and not a placeholder: an item with nothing to say
        should say nothing."""
        for empty in ("", None, "---"):
            self.assertEqual(host_mark(empty), "")

    def test_it_is_derived_from_the_NAME_alone(self):
        """Never from the set on screen. A set-aware rule could guarantee
        uniqueness, but the mark would then change when you latched somewhere
        new -- and a label that moves is worse than one that rarely collides,
        because you stop trusting any of them."""
        self.assertEqual(host_mark("manifold"), "MLD")   # same answer, always


class MarkOnTheTile(unittest.TestCase):
    def test_TWO_HOSTS_WITH_THE_SAME_COLOUR_DIFFER(self):
        """The property the whole feature exists for. `manifestor` and
        `manifold` hash to the identical pair on a box with no hosts file, so
        before the mark their tray items were pixel-for-pixel the same."""
        pair = parse_pair("#ffffff #005f87")
        a = icon_pixmap("working", 2, host=pair, mark=host_mark("manifold"))
        b = icon_pixmap("working", 2, host=pair, mark=host_mark("manifestor"))
        self.assertNotEqual(a[0][2], b[0][2])

    def test_no_mark_renders_EXACTLY_as_before(self):
        """One host on the tray keeps the look it has always had, byte for
        byte. The mark is for telling several apart; a lone item has nobody to
        be told apart from, and that is every new user's first impression."""
        pair = parse_pair("#d0d0d0 #303030")
        self.assertEqual(icon_pixmap("idle", None, host=pair, mark=None),
                         icon_pixmap("idle", None, host=pair))

    def test_no_mark_ink_is_a_state_colour(self):
        """None of them may read as a state. A state-coloured mark was tried
        and rejected: it was the most legible option of all, and it made host
        identity flicker as the agent worked -- the one thing identity may not
        do. Widening the palette is the way that creeps back in, one plausible
        hue at a time, so every slot is checked rather than the first one."""
        for c in (MARK_LOCAL_INK,) + tuple(MARK_PALETTE):
            self.assertNotIn(c, STATE_FRAME.values())
            self.assertNotIn(c, STATE_BADGE.values())

    def test_local_is_reserved_and_not_in_the_rotation(self):
        """White is home's, and only home's. If it were also a palette slot a
        remote could be drawn as the local box, which is the one confusion this
        whole colour scheme exists to prevent."""
        self.assertNotIn(MARK_LOCAL_INK, MARK_PALETTE)
        self.assertIs(mark_ink(None), MARK_LOCAL_INK)
        for slot in range(len(MARK_PALETTE)):
            self.assertNotEqual(mark_ink(slot), MARK_LOCAL_INK)

    def test_every_palette_slot_is_distinct(self):
        """The palette's entire job is telling hosts apart, so two equal
        entries would be a silent regression: the tray would still draw, and
        two machines would quietly share an identity."""
        self.assertEqual(len(set(MARK_PALETTE)), len(MARK_PALETTE))

    def test_a_slot_past_the_end_WRAPS(self):
        """More remotes than slots must degrade, never crash or blank. Colour
        is a redundant hint and the letters stay unique, so a shared hue is the
        correct answer at that point."""
        n = len(MARK_PALETTE)
        self.assertEqual(mark_ink(n), mark_ink(0))
        self.assertEqual(mark_ink(n + 3), mark_ink(3))

    def test_the_ink_actually_reaches_the_pixels(self):
        """Two hosts with the same LETTERS and different slots must differ.

        Separate from the palette-table assertions above, which prove the table
        is sane and prove nothing about whether _tile consults it. Passing the
        slot and ignoring it would leave every one of them green."""
        a = icon_pixmap("working", 2, mark="MLD", ink=0)
        b = icon_pixmap("working", 2, mark="MLD", ink=1)
        self.assertNotEqual(a, b)
        self.assertNotEqual(icon_pixmap("working", 2, mark="MLD", ink=None), a)

    def test_state_still_reads_under_a_mark(self):
        """The mark must not swallow the signal it sits beside."""
        pair = parse_pair("#ffffff #005f87")
        seen = {}
        for st in STATES:
            k = bytes(icon_pixmap(st, 2, host=pair, mark="MLD")[0][2])
            self.assertIsNone(seen.get(k),
                              f"{st} == {seen.get(k)} under a mark")
            seen[k] = st

    def test_the_STRIP_itself_is_drawn(self):
        """Separate from the letters, because either alone makes a marked tile
        differ from an unmarked one -- so a single "they differ" assertion
        kills NEITHER. Same shape as unknown's frame-vs-badge and the host
        pair's screen-vs-prompt: when a feature reaches the output through more
        than one path, assert each path.

        Sampled at the left edge, mid-height, which is inside the strip and
        beside the middle letter rather than on it. Without a mark that pixel
        is the state's FRAME; with one it is the strip.
        """
        from mux_indicator.render import _MARK_BACK, _tile
        pair = parse_pair("#ffffff #005f87")
        for s in (22, 32, 48):
            marked = _tile("working", 2, s, True, pair, "MLD").load()
            plain = _tile("working", 2, s, True, pair).load()
            self.assertEqual(marked[1, s // 2], _MARK_BACK,
                             f"{s}px: no strip behind the mark")
            self.assertNotEqual(plain[1, s // 2], _MARK_BACK,
                                f"{s}px: the UNMARKED tile already has one")

    def test_the_mark_is_sized_by_HEIGHT_not_width(self):
        """The one choice that made it legible. Fitting the glyph to a narrow
        column gave a 7px capital on a 32px tile -- present, unreadable, and
        indistinguishable between hosts at the size a tray actually draws. The
        letters are sized to a third of the tile and allowed to be as wide as
        they need, because the strip beneath them means width costs nothing.
        """
        from mux_indicator.render import _mark_metrics
        for s in (32, 48):
            f, _w = _mark_metrics(s, "MLD")
            bb = f.getbbox("M")
            cap = bb[3] - bb[1]
            self.assertGreaterEqual(
                cap, 0.70 * (s / 3.0),
                f"{s}px: cap height {cap} is far below a third of the tile, "
                "which is what a width-constrained fit produces")

    def test_THE_OVERLAY_IS_CONFINED_TO_ITS_STRIP(self):
        """Outside its own band the marked tile is the HOST-NEUTRAL tile,
        pixel for pixel, at every size and state.

        That is the property the whole design rests on. The mark is allowed to
        obliterate the chevron precisely BECAUSE stripping the letters restores
        a standard icon; if the overlay could disturb anything outside its own
        band, "remove the mark to revert" would stop being true.

        Compared against the NEUTRAL tile rather than the tinted one, which is
        the 0.48 change: a marked tile deliberately drops the host tint, so the
        old comparison would now fail for the right reason and hide this one.
        """
        from mux_indicator.render import _mark_metrics, _tile
        pair = parse_pair("#ffffff #005f87")
        for st in STATES:
            for s in (22, 32, 48):
                plain = _tile(st, 2, s, True, None).load()
                marked = _tile(st, 2, s, True, pair, "MLD", 1).load()
                _f, w = _mark_metrics(s, "MLD")
                for x in range(int(w) + 1, s):
                    for y in range(s):
                        self.assertEqual(
                            plain[x, y], marked[x, y],
                            f"{st} {s}px: the mark changed a pixel at x={x} "
                            f"y={y}, outside its {w}px strip")

    def test_a_marked_tile_DROPS_the_host_tint(self):
        """Two host colours on one tile disagree with each other, so while a
        mark is up the tint steps aside and the mark is the only host channel.

        Asserted in both directions, because each is a different bug: still
        tinting means the tile says two things at once, and dropping the tint
        when UNMARKED would change the single-host icon that must not move.
        """
        a = icon_pixmap("working", 2, host=parse_pair("#ffffff #005f87"),
                        mark="MLD", ink=1)
        b = icon_pixmap("working", 2, host=parse_pair("#ffffff #870000"),
                        mark="MLD", ink=1)
        self.assertEqual(a, b, "the host tint survived under a mark")
        c = icon_pixmap("working", 2, host=parse_pair("#ffffff #005f87"))
        d = icon_pixmap("working", 2, host=parse_pair("#ffffff #870000"))
        self.assertNotEqual(c, d, "the UNMARKED tile stopped using its tint")

    def test_the_strip_is_sized_from_the_LETTERS(self):
        """Strip and glyphs come from one measurement. Computed apart they
        drift, and a letter hanging off the end of its own background is the
        exact failure the strip exists to prevent."""
        from mux_indicator.render import _mark_metrics
        for s in (22, 32, 48, 64):
            f, w = _mark_metrics(s, "MLD")
            widest = max(f.getbbox(c)[2] - f.getbbox(c)[0] for c in "MLD")
            self.assertGreaterEqual(w, widest,
                                    f"{s}px: strip {w} narrower than a letter")

    def test_it_draws_at_every_offered_size(self):
        """Including the smallest, where it is cramped: a tray host picks the
        size, and returning a buffer that ignored the mark at one size would be
        an item that changes identity with the bar's settings."""
        pair = parse_pair("#ffffff #005f87")
        for w, h, buf in icon_pixmap("idle", None, host=pair, mark="MLD"):
            plain = dict((a, c) for a, b, c in
                         icon_pixmap("idle", None, host=pair))
            self.assertNotEqual(buf, plain[w], f"no mark drawn at {w}px")


class Deterministic(unittest.TestCase):
    def test_same_input_same_bytes(self):
        """No clock, no randomness. A repaint must not flicker the picture."""
        self.assertEqual(icon_pixmap("blocked", 2), icon_pixmap("blocked", 2))


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
