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

    def test_A_GRANDCHILD_HOLDING_THE_PIPE_CANNOT_STALL_US(self):
        """The 30s freeze, which the test above could not see.

        `test_A_HANG_BECOMES_UNKNOWN` asserts the VERDICT and not the DURATION,
        so it passed happily while this bug was live: _query did return
        `unknown`, thirty seconds later. Its stub also sleeps in the DIRECT
        child, which `proc.kill()` reaps by itself, so it never reached the
        mechanism that was broken.

        What broke it: killing the direct child leaves a GRANDCHILD holding the
        stdout pipe, and `communicate()` then waits for the grandchild rather
        than the child -- measured at 30s against a `sleep 30` source with the
        0.3s timeout firing correctly all along. The whole host's poll loop
        stalls for the grandchild's lifetime, which is the exact freeze the
        timeout exists to prevent, reintroduced through the reaping path. The
        fix is `start_new_session=True` plus a process-GROUP kill.

        The shell below exits IMMEDIATELY and leaves a background sleep holding
        the pipe. A source is an arbitrary command, so a wrapper that spawns a
        child is the normal case, not an edge one.
        """
        import shutil
        import subprocess
        import time
        # A duration nothing else on this machine will be sleeping for, so the
        # survivor check below cannot match somebody else's process.
        mark = "4919"
        sni = _fresh(MUX_INDICATOR_TIMEOUT="0.3")
        began = time.monotonic()
        got = asyncio.run(sni._query(["sh", "-c", f"sleep {mark} & exit 0"]))
        took = time.monotonic() - began
        self.assertEqual(got, ("unknown", None))
        # THE DURATION IS ONE ASSERTION. Generous against a loaded machine and
        # still far below the 30s the bug produced.
        self.assertLess(took, 5.0,
                        f"_query took {took:.1f}s: a grandchild is holding "
                        "the stdout pipe and the group kill is not reaping it")

        # AND THE SURVIVOR IS THE OTHER, because they fail differently and a
        # single assertion would kill neither mutation. The bounded wait after
        # the kill already caps the DURATION even with no group kill at all, so
        # timing alone cannot see `killpg` being lost -- what is lost then is
        # the grandchild, which outlives the query as a leaked process, one per
        # poll, for as long as the host stays unreachable.
        # `-xf`, an EXACT full-command-line match, not a substring one. A bare
        # `-f` also matches any shell whose own argv happens to mention the
        # pattern -- including the process running this suite -- which is the
        # self-match trap this project has already paid for once with
        # `pkill -f "python -m mux_indicator"`. Measured here: 3 matches loose
        # against 1 exact.
        if shutil.which("pgrep"):
            alive = subprocess.run(["pgrep", "-xf", f"sleep {mark}"],
                                   capture_output=True, text=True)
            for pid in alive.stdout.split():
                try:                      # never leave one behind on failure
                    os.kill(int(pid), 9)
                except (OSError, ValueError):
                    pass
            self.assertEqual(alive.returncode, 1,
                             "the grandchild SURVIVED the timeout: the group "
                             "kill did not reach it, so every poll against an "
                             "unreachable host leaks a process")

    def test_the_hang_path_is_BOUNDED_not_merely_correct(self):
        """The same omission for the ordinary hang: assert it returns promptly,
        not just that it eventually says `unknown`. A deadline nobody times is
        indistinguishable from no deadline at all."""
        import time
        sni = _fresh(MUX_INDICATOR_TIMEOUT="0.3")
        began = time.monotonic()
        asyncio.run(sni._query([self._stub("idle 0\n", 0, sleep=30)]))
        self.assertLess(time.monotonic() - began, 5.0,
                        "the timeout did not bound the call")

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
        self.assertIsNone(self.sni.Indicator(label="northwood")._mark)

    def test_setting_a_mark_changes_the_pixels(self):
        i = self.sni.Indicator(label="northwood")
        before = i._pixmap
        i.set_mark("NWD")
        self.assertNotEqual(before, i._pixmap)

    def test_clearing_it_returns_the_original(self):
        """Detaching from your last remote must give back exactly the
        single-host tile, not a near-miss of it."""
        i = self.sni.Indicator(label="northwood")
        before = i._pixmap
        i.set_mark("NWD")
        i.set_mark(None)
        self.assertEqual(before, i._pixmap)

    def test_an_unchanged_mark_does_not_repaint(self):
        """The discovery loop calls this every tick. Repainting regardless
        would emit NewIcon at the poll rate and churn the tray for nothing."""
        i = self.sni.Indicator(label="northwood")
        i.set_mark("NWD")
        first = i._pixmap
        i.set_mark("NWD")
        self.assertIs(first, i._pixmap)

    def test_a_CHANGED_INK_repaints_even_when_the_mark_is_the_same(self):
        """Separate from the assertion above, and the pair of them is the
        point: comparing only the mark makes the no-repaint shortcut pin a
        host to the first colour it was ever drawn with, so a reshuffle would
        be invisible until something unrelated forced a repaint."""
        i = self.sni.Indicator(label="northwood")
        i.set_mark("NWD", 0)
        first = i._pixmap
        i.set_mark("NWD", 2)
        self.assertNotEqual(first, i._pixmap)

    def test_the_ink_reaches_the_icon(self):
        """Two items, same letters, different slots. Storing the ink and never
        passing it to the renderer would leave every host one colour."""
        a, b = (self.sni.Indicator(label="x") for _ in range(2))
        a.set_mark("NWD", 0)
        b.set_mark("NWD", 1)
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
        self.assertEqual(self.sni.mark_plan(["northwood"], "northwood", self.s),
                         {"northwood": (None, None)})

    def test_the_LOCAL_host_takes_no_slot(self):
        """White is reserved for home. Giving it a palette slot would mean the
        machine you are sitting at changed colour when you latched elsewhere."""
        p = self.sni.mark_plan(["northwood", "rover"], "northwood", self.s)
        self.assertEqual(p["northwood"], ("NWD", None))
        self.assertIsNotNone(p["rover"][1])

    def test_every_remote_gets_a_mark_AND_a_slot(self):
        p = self.sni.mark_plan(["northwood", "rover", "atlas"], "northwood",
                               self.s)
        self.assertEqual(p["northwood"][1], None)
        self.assertEqual(sorted(p), ["atlas", "northwood", "rover"])
        for lab in ("rover", "atlas"):
            self.assertEqual(p[lab][0], self.sni.host_mark(lab))
            self.assertIn(p[lab][1], range(5))

    def test_remotes_do_not_collide_with_each_other(self):
        labs = ["northwood", "rover", "atlas", "nimbus"]
        p = self.sni.mark_plan(labs, "northwood", self.s)
        inks = [p[lab][1] for lab in labs if lab != "northwood"]
        self.assertEqual(len(set(inks)), len(inks))

    def test_a_tray_with_no_local_host_still_works(self):
        """`local` naming nobody present is not an error: the local item can be
        absent from a tray built entirely of remotes, and every one of them
        must then get a slot rather than one silently claiming white."""
        p = self.sni.mark_plan(["rover", "atlas"], "northwood", self.s)
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
        self.assertEqual(self.sni.Indicator(label="northwood").Id,
                         "mux-northwood")

    def test_unlabelled_keeps_the_historical_id(self):
        self.assertEqual(self.sni.Indicator().Id, "mux-indicator")

    def test_tooltip_title_names_the_HOST(self):
        tip = self.sni.Indicator(label="northwood").ToolTip
        self.assertEqual(tip[2], "mux @ northwood")

    def test_two_labels_never_share_an_id(self):
        """Two items with one id is a tray that cannot tell them apart."""
        a = self.sni.Indicator(label="northwood").Id
        b = self.sni.Indicator(label="northgate").Id
        self.assertNotEqual(a, b)

    def test_unknown_tooltip_says_it_cannot_reach_the_host(self):
        """Not "all sessions idle", which is what the count-is-None branch would
        otherwise say -- a calm sentence about a host we cannot see."""
        i = self.sni.Indicator(state="unknown", count=None, label="northwood")
        self.assertIn("cannot reach", i.ToolTip[3])

    def test_unknown_is_not_NeedsAttention(self):
        """Only `blocked` earns attention. An unreachable host is not an
        agent waiting on you, and escalating it would cry wolf on every
        network blip."""
        i = self.sni.Indicator(state="unknown", label="h")
        self.assertEqual(i.Status, "Active")


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()


class Reconcile(unittest.TestCase):
    """The supervisor's set diff, which is what the whole daemon turns on.

    Extracted from the async loop for the same reason mark_plan was: it needs a
    bus, so nothing inside it could be asserted at all. `_supervise` and
    `_publish` held every live bug this feature has ever had -- the ignored exit
    code, the hanging source, the SIGKILL AttributeError -- and a 2026-09-26
    coverage sweep put them at the bottom of the file at 56%.
    """

    def setUp(self):
        self.sni = _fresh()

    def test_a_new_host_is_added(self):
        drop, add = self.sni.reconcile({"rover": ["a"]}, {})
        self.assertEqual(drop, [])
        self.assertEqual(add, [("rover", ["a"])])

    def test_a_departed_host_is_dropped(self):
        drop, add = self.sni.reconcile({}, {"rover": object()})
        self.assertEqual(drop, ["rover"])
        self.assertEqual(add, [])

    def test_AN_UNCHANGED_HOST_IS_LEFT_ALONE(self):
        """The rule no set-based assertion would catch. Tearing every item down
        and republishing it each tick still converges on the right set, while
        the tray flickers every DISCOVER seconds and leaks a bus connection per
        host per pass. Already correct must mean untouched, not recreated."""
        want = {"rover": ["a"], "atlas": ["b"]}
        live = {"rover": object(), "atlas": object()}
        self.assertEqual(self.sni.reconcile(want, live), ([], []))

    def test_a_mixed_tick_does_both_and_nothing_else(self):
        want = {"rover": ["a"], "atlas": ["b"]}
        live = {"rover": object(), "nimbus": object()}
        drop, add = self.sni.reconcile(want, live)
        self.assertEqual(drop, ["nimbus"])
        self.assertEqual(add, [("atlas", ["b"])])

    def test_the_argv_travels_with_the_label(self):
        """The pair is what gets published. Dropping the argv would publish a
        host against whatever command happened to be next."""
        _d, add = self.sni.reconcile({"a": ["x", "1"], "b": ["y"]}, {})
        self.assertEqual(dict(add), {"a": ["x", "1"], "b": ["y"]})

    def test_an_empty_tick_is_quiet(self):
        """Nothing latched and nothing published is not an event. This is the
        condition the 'watching ...' line is gated on, so a truthy answer here
        would log every DISCOVER seconds forever."""
        self.assertEqual(self.sni.reconcile({}, {}), ([], []))


class BusName(unittest.TestCase):
    def setUp(self):
        self.sni = _fresh()

    def test_the_name_is_one_based_and_per_process(self):
        self.assertEqual(self.sni.item_bus_name(42, 1),
                         "org.kde.StatusNotifierItem-42-1")

    def test_every_index_gives_a_DIFFERENT_name(self):
        """Two items on one connection resolve to the same exported object if
        they share a name, and you get the same tray icon twice."""
        names = {self.sni.item_bus_name(7, i) for i in range(1, 6)}
        self.assertEqual(len(names), 5)


class Reregister(unittest.TestCase):
    """Re-announce when the tray watcher appears, and only then."""

    def setUp(self):
        self.sni = _fresh()

    def test_the_watcher_ARRIVING_triggers_it(self):
        self.assertTrue(self.sni.wants_reregister(self.sni.WATCHER, ":1.42"))

    def test_the_watcher_LEAVING_does_not(self):
        """An empty new owner is the watcher going away, which is when
        registering is both pointless and guaranteed to fail."""
        self.assertFalse(self.sni.wants_reregister(self.sni.WATCHER, ""))

    def test_ANOTHER_name_changing_does_not(self):
        """The session bus is busy. Reacting to every NameOwnerChanged would
        be a registration storm against a watcher that never moved."""
        self.assertFalse(self.sni.wants_reregister("org.example.Thing",
                                                   ":1.9"))
