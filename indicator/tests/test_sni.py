"""sni.py's non-D-Bus half: what the indicator BELIEVES, before it draws.

The D-Bus service needs a live session bus and a tray host, so it is integration
territory. Everything that decides WHAT to show is pure, and it is where the
interesting mistakes are -- because every one of them ends with a tray icon
confidently showing the wrong thing, which nobody can tell from the right thing.

The rule the whole feed rests on, and the one these tests exist to protect:

  AN EMPTY ANSWER IS AN ANSWER. `mux agent-summary` prints `none 0` and exits 0
  on a host with no agents. A FAILURE to run it -- mux missing, the host
  unreachable -- is a different fact entirely. If those two collapse into one,
  the tray draws a calm icon for a machine it cannot see, which is the exact
  failure this indicator exists to prevent.
"""
import asyncio
import importlib
import os
import unittest


def _fresh(**env):
    """Re-import sni with a patched environment.

    Its module-level constants (MUX, POLL, CTL) are read at import time, so a
    test that wants a different one has to reload rather than assign -- and a
    test that forgot would silently exercise the developer's own environment.
    """
    old = {k: os.environ.get(k) for k in env}
    os.environ.update({k: v for k, v in env.items() if v is not None})
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
    try:
        import mux_indicator.sni as sni
        return importlib.reload(sni)
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class Parse(unittest.TestCase):
    """`<state> <count>` -> (state, count), the shape agent-summary emits."""

    def setUp(self):
        self.sni = _fresh()

    def test_state_and_count(self):
        self.assertEqual(self.sni._parse("working 3"), ("working", 3))
        self.assertEqual(self.sni._parse("blocked 12"), ("blocked", 12))

    def test_trailing_newline_and_padding(self):
        """agent-summary ends with a newline; ssh may add whitespace."""
        self.assertEqual(self.sni._parse("  working   3  \n"), ("working", 3))

    def test_idle_and_none_carry_no_number(self):
        """Their badges are a check and nothing, so a count would be drawn as a
        number the state does not have. Normalised away here as well as in the
        renderer -- this one is about MEANING, the renderer's is about ink."""
        self.assertEqual(self.sni._parse("idle 5"), ("idle", None))
        self.assertEqual(self.sni._parse("none 0"), ("none", None))

    def test_unreadable_count_is_no_count_not_zero(self):
        """`-` or a non-number must not become 0.

        Zero is a CLAIM ("nothing is waiting"); absent is the absence of one.
        Rendering 0 in the badge would say the opposite of what happened.
        """
        self.assertEqual(self.sni._parse("blocked -"), ("blocked", None))
        self.assertEqual(self.sni._parse("blocked wat"), ("blocked", None))
        self.assertEqual(self.sni._parse("blocked"), ("blocked", None))

    def test_empty_input_is_none_not_a_state(self):
        """Nothing read is not a state. Returning one would paint a value that
        was never reported -- and `_watch` keys "did it change" off this."""
        self.assertIsNone(self.sni._parse(""))
        self.assertIsNone(self.sni._parse("   \n"))

    def test_an_unknown_state_word_passes_through(self):
        """A newer or older mux may say something this one does not know. The
        renderer falls back for unknown words, so passing it through is
        survivable; inventing a known state here would not be."""
        self.assertEqual(self.sni._parse("frobnicating 2"),
                         ("frobnicating", 2))


class Override(unittest.TestCase):
    """The manual override file, which must be OPT-IN.

    Unset means the deployed service reads only the live feed, so no stray file
    can silently pin the tray to a value that has nothing to do with reality.

    NOT TESTED HERE: that the handle is closed. `open(CTL).read()` raised a
    ResourceWarning, which looked like an fd leak on a path that runs every
    poll -- but CPython's refcounting closes it the instant .read() returns, so
    a descriptor count before and after is identical either way. The assertion
    could not fail, so it is gone rather than kept as decoration; the `with` in
    sni.py stands on not depending on an implementation detail.
    """

    def test_unset_means_no_override(self):
        sni = _fresh(MUX_INDICATOR_CTL=None)
        self.assertIsNone(sni._read_override())

    def test_missing_file_is_not_an_override(self):
        sni = _fresh(MUX_INDICATOR_CTL="/nonexistent/mux-indicator-ctl")
        self.assertIsNone(sni._read_override())

    def test_set_and_readable_is_honoured(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".ctl",
                                         delete=False) as fh:
            fh.write("blocked 4\n")
            path = fh.name
        try:
            sni = _fresh(MUX_INDICATOR_CTL=path)
            self.assertEqual(sni._read_override(), ("blocked", 4))
        finally:
            os.unlink(path)


class Query(unittest.TestCase):
    """Running a source, and telling "quiet" from "could not ask".

    THE EXIT CODE IS THE CONTRACT, and ignoring it was a real bug. `mux
    agent-summary` prints `none 0` and exits 0 on a host with no agents, so
    EMPTY IS EXIT 0 and a quiet host is a genuine answer. A non-zero exit has
    no meaning of its own -- it can only be the transport -- so it must become
    UNKNOWN.

    The old `_query_mux` read stdout and never checked the status. A failed
    ssh produced empty output, which parsed to None, which the caller read as
    "no change" -- so it left the previous icon up, and an unreachable machine
    kept showing whatever it last said, forever. These tests exist so that
    cannot come back.
    """

    def _stub(self, out, rc, sleep=0):
        import stat
        import tempfile
        fd, path = tempfile.mkstemp(prefix="muxstub", suffix=".sh")
        with os.fdopen(fd, "w") as fh:
            fh.write("#!/bin/sh\n")
            if sleep:
                fh.write("sleep %d\n" % sleep)
            fh.write("printf '%s'\nexit %d\n" % (out, rc))
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.addCleanup(os.unlink, path)
        return path

    def test_exit_zero_output_is_parsed(self):
        sni = _fresh()
        self.assertEqual(
            asyncio.run(sni._query([self._stub("working 2\n", 0)])),
            ("working", 2))

    def test_an_empty_answer_is_still_an_answer(self):
        """`none 0` from a host with no agents is a FACT, and exits 0. It must
        NOT be confused with a failure -- that is the whole distinction."""
        sni = _fresh()
        self.assertEqual(
            asyncio.run(sni._query([self._stub("none 0\n", 0)])),
            ("none", None))

    def test_a_NONZERO_exit_is_unknown(self):
        """Even with plausible output on stdout. The status wins, because only
        the transport can have failed."""
        sni = _fresh()
        self.assertEqual(
            asyncio.run(sni._query([self._stub("idle 0\n", 255)])),
            ("unknown", None))

    def test_a_missing_binary_is_unknown_not_none(self):
        """The daemon outlives a broken PATH, and says it cannot see the host
        rather than returning None for the caller to misread as "no change"."""
        sni = _fresh()
        self.assertEqual(
            asyncio.run(sni._query(["/nonexistent/definitely-not-mux"])),
            ("unknown", None))

    def test_exit_zero_but_unparseable_is_unknown(self):
        """A feed that answers nothing has not told us the host is calm."""
        sni = _fresh()
        self.assertEqual(asyncio.run(sni._query([self._stub("", 0)])),
                         ("unknown", None))

    def test_A_HANG_BECOMES_UNKNOWN(self):
        """The case that makes `unknown` reachable at all. ssh into a blackholed
        host does not fail, it SLEEPS -- so without a deadline the item would
        freeze on its last value indefinitely, showing a calm icon for a machine
        that fell off the network. That is the exact failure this feature exists
        to prevent, so the timeout is load-bearing, not a nicety.
        """
        sni = _fresh(MUX_INDICATOR_TIMEOUT="0.3")
        self.assertEqual(
            asyncio.run(sni._query([self._stub("idle 0\n", 0, sleep=30)])),
            ("unknown", None))

    def test_a_state_word_mux_NEVER_EMITS_is_unknown(self):
        """A feed can return plausible garbage. A mis-quoted ssh source ran the
        remote session PICKER, whose output parsed to the state `1)`, which the
        renderer draws with the `none` fallback: a calm tile for a host whose
        feed is broken. The exit code alone did not catch it (that picker
        happened to fail; a feed returning junk and exiting 0 would not).
        """
        sni = _fresh()
        self.assertEqual(
            asyncio.run(sni._query([self._stub(" 1) bootique\n", 0)])),
            ("unknown", None))

    def test_parse_still_passes_words_through(self):
        """The validation lives in _query, not _parse: _parse stays a pure
        text->tuple function, and deciding what to TRUST sits with the exit
        code. Keeping them separate is why the renderer can still have its own
        fallback for a word it does not know."""
        sni = _fresh()
        self.assertEqual(sni._parse("frobnicating 2"), ("frobnicating", 2))

    def test_never_returns_None(self):
        """The caller compares against its last value to decide whether to
        repaint; a None would be read as "unchanged" and is what let a stale
        icon persist. Every path must yield a state."""
        sni = _fresh(MUX_INDICATOR_TIMEOUT="0.3")
        for argv in (["/nonexistent/x"], [self._stub("", 0)],
                     [self._stub("x", 3)]):
            self.assertIsNotNone(asyncio.run(sni._query(argv)))


class HostColour(unittest.TestCase):
    """Resolving a host's identity colours: LOCAL, once, and fail-soft.

    Run locally even for a remote host, which is the point and not a shortcut:
    the colour derives from the NAME by hashing, so this box can colour a remote
    host with nothing shared. Asking the remote would need it reachable just to
    pick a colour -- so an unreachable host would lose its identity at the exact
    moment the `unknown` glyph needs to say which host is unreachable.
    """

    def _stub(self, out, rc):
        import stat
        import tempfile
        fd, path = tempfile.mkstemp(prefix="muxhc", suffix=".sh")
        with os.fdopen(fd, "w") as fh:
            fh.write("#!/bin/sh\nprintf '%s'\nexit %d\n" % (out, rc))
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.addCleanup(os.unlink, path)
        return path

    def test_a_pair_is_parsed(self):
        sni = _fresh(MUX_BIN=self._stub("#d0d0d0 #303030\n", 0))
        self.assertEqual(asyncio.run(sni._host_colors("h")),
                         ((0xD0, 0xD0, 0xD0, 0xFF), (0x30, 0x30, 0x30, 0xFF)))

    def test_the_REFUSAL_is_honoured(self):
        """Exit 1 for colours 0-15. Drawing neutral is correct; inventing a
        colour for a machine identifier is not."""
        sni = _fresh(MUX_BIN=self._stub("", 1))
        self.assertIsNone(asyncio.run(sni._host_colors("h")))

    def test_a_missing_mux_is_not_fatal(self):
        """An item with no colour is a small loss. An item that never publishes
        because a colour lookup raised is a host missing from the tray."""
        sni = _fresh(MUX_BIN="/nonexistent/definitely-not-mux")
        self.assertIsNone(asyncio.run(sni._host_colors("h")))

    def test_no_label_asks_nothing(self):
        """The single-host default has no label, so there is no name to hash and
        no subprocess worth spawning."""
        sni = _fresh(MUX_BIN=self._stub("#d0d0d0 #303030\n", 0))
        self.assertIsNone(asyncio.run(sni._host_colors("")))


class Mark(unittest.TestCase):
    """The mark appears when a second host joins and goes when it leaves.

    That is the rule the supervisor enforces, and the reason set_mark exists at
    all rather than the mark being fixed at construction: hosts come and go as
    you latch and detach, so an item has to be able to gain and lose its label
    without being torn down and republished.
    """

    def setUp(self):
        self.sni = _fresh()

    def test_an_item_starts_unmarked(self):
        """One host is the common case, so it is also the default."""
        self.assertIsNone(self.sni.Indicator(label="manifold")._mark)

    def test_setting_a_mark_changes_the_pixels(self):
        i = self.sni.Indicator(label="manifold")
        before = i._pixmap
        i.set_mark("MLD")
        self.assertNotEqual(before, i._pixmap)

    def test_clearing_it_returns_the_original(self):
        """Detaching from your last remote must give back exactly the
        single-host tile, not a near-miss of it."""
        i = self.sni.Indicator(label="manifold")
        before = i._pixmap
        i.set_mark("MLD")
        i.set_mark(None)
        self.assertEqual(before, i._pixmap)

    def test_an_unchanged_mark_does_not_repaint(self):
        """The discovery loop calls this every tick. Repainting regardless
        would emit NewIcon at the poll rate and churn the tray for nothing."""
        i = self.sni.Indicator(label="manifold")
        i.set_mark("MLD")
        first = i._pixmap
        i.set_mark("MLD")
        self.assertIs(first, i._pixmap)

    def test_a_CHANGED_INK_repaints_even_when_the_mark_is_the_same(self):
        """Separate from the assertion above, and the pair of them is the
        point: comparing only the mark makes the no-repaint shortcut pin a
        host to the first colour it was ever drawn with, so a reshuffle would
        be invisible until something unrelated forced a repaint."""
        i = self.sni.Indicator(label="manifold")
        i.set_mark("MLD", 0)
        first = i._pixmap
        i.set_mark("MLD", 2)
        self.assertNotEqual(first, i._pixmap)

    def test_the_ink_reaches_the_icon(self):
        """Two items, same letters, different slots. Storing the ink and never
        passing it to the renderer would leave every host one colour."""
        a, b = (self.sni.Indicator(label="x") for _ in range(2))
        a.set_mark("MLD", 0)
        b.set_mark("MLD", 1)
        self.assertNotEqual(a._pixmap, b._pixmap)


class MarkPlan(unittest.TestCase):
    """Who gets a mark, and which slot -- the supervisor's two rules, lifted
    out of its async loop so they can be asserted at all."""

    def setUp(self):
        import tempfile
        from mux_indicator.slots import Slots
        self.sni = _fresh()
        self.s = Slots(5, os.path.join(tempfile.mkdtemp(), "slots"))

    def test_one_host_gets_no_mark_at_all(self):
        """The single-host tray must not change, and that includes the local
        box being alone: nothing to be told apart from."""
        self.assertEqual(self.sni.mark_plan(["manifold"], "manifold", self.s),
                         {"manifold": (None, None)})

    def test_the_LOCAL_host_takes_no_slot(self):
        """White is reserved for home. Giving it a palette slot would mean the
        machine you are sitting at changed colour when you latched elsewhere."""
        p = self.sni.mark_plan(["manifold", "rover"], "manifold", self.s)
        self.assertEqual(p["manifold"], ("MLD", None))
        self.assertIsNotNone(p["rover"][1])

    def test_every_remote_gets_a_mark_AND_a_slot(self):
        p = self.sni.mark_plan(["manifold", "rover", "atlas"], "manifold",
                               self.s)
        self.assertEqual(p["manifold"][1], None)
        self.assertEqual(sorted(p), ["atlas", "manifold", "rover"])
        for lab in ("rover", "atlas"):
            self.assertEqual(p[lab][0], self.sni.host_mark(lab))
            self.assertIn(p[lab][1], range(5))

    def test_remotes_do_not_collide_with_each_other(self):
        labs = ["manifold", "rover", "atlas", "nimbus"]
        p = self.sni.mark_plan(labs, "manifold", self.s)
        inks = [p[lab][1] for lab in labs if lab != "manifold"]
        self.assertEqual(len(set(inks)), len(inks))

    def test_a_tray_with_no_local_host_still_works(self):
        """`local` naming nobody present is not an error: the local item can be
        absent from a tray built entirely of remotes, and every one of them
        must then get a slot rather than one silently claiming white."""
        p = self.sni.mark_plan(["rover", "atlas"], "manifold", self.s)
        for lab in ("rover", "atlas"):
            self.assertIsNotNone(p[lab][1])


class Identity(unittest.TestCase):
    """What a tray host and a human see when there are SEVERAL items.

    With one item "mux" was enough. With one per host it identifies nothing, so
    the label has to reach the id (which a bar orders on, and which appears in
    the watcher's name list) and the tooltip (which is what you hover to ask
    "which machine is this?").
    """

    def setUp(self):
        self.sni = _fresh()

    def test_id_carries_the_label_and_keeps_the_prefix(self):
        """The `mux-` prefix keeps a bar's existing tray `order` working, and
        the suffix makes the id self-describing on the bus."""
        self.assertEqual(self.sni.Indicator(label="manifold").Id,
                         "mux-manifold")

    def test_unlabelled_keeps_the_historical_id(self):
        self.assertEqual(self.sni.Indicator().Id, "mux-indicator")

    def test_tooltip_title_names_the_HOST(self):
        tip = self.sni.Indicator(label="manifold").ToolTip
        self.assertEqual(tip[2], "mux @ manifold")

    def test_two_labels_never_share_an_id(self):
        """Two items with one id is a tray that cannot tell them apart."""
        a = self.sni.Indicator(label="manifold").Id
        b = self.sni.Indicator(label="manifestor").Id
        self.assertNotEqual(a, b)

    def test_unknown_tooltip_says_it_cannot_reach_the_host(self):
        """Not "all sessions idle", which is what the count-is-None branch would
        otherwise say -- a calm sentence about a host we cannot see."""
        i = self.sni.Indicator(state="unknown", count=None, label="manifold")
        self.assertIn("cannot reach", i.ToolTip[3])

    def test_unknown_is_not_NeedsAttention(self):
        """Only `blocked` earns attention. An unreachable host is not an
        agent waiting on you, and escalating it would cry wolf on every
        network blip."""
        i = self.sni.Indicator(state="unknown", label="h")
        self.assertEqual(i.Status, "Active")


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
