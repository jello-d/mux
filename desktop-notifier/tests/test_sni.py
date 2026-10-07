"""sni.py's non-D-Bus half: what the indicator BELIEVES, before it draws.

The D-Bus service needs a live session bus and a tray host, so it is integration
territory. Everything that decides WHAT to show is pure, and it is where the
interesting mistakes are, because every one of them ends with a tray icon
confidently showing the wrong thing, which nobody can tell from the right thing.

The rule the whole feed rests on, and the one these tests exist to protect:

  AN EMPTY ANSWER IS AN ANSWER. `mux agent-summary` prints `none 0` and exits 0
  on a host with no agents. A FAILURE to run it (mux missing, the host
  unreachable) is a different fact entirely. If those two collapse into one,
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
    test that wants a different one has to reload rather than assign, and a
    test that forgot would silently exercise the developer's own environment.
    """
    old = {k: os.environ.get(k) for k in env}
    os.environ.update({k: v for k, v in env.items() if v is not None})
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
    try:
        import mux_desktop_notifier.sni as sni
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
        renderer: this one is about MEANING, the renderer's is about ink."""
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
        was never reported, and `_watch` keys "did it change" off this."""
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
    poll, but CPython's refcounting closes it the instant .read() returns, so
    a descriptor count before and after is identical either way. The assertion
    could not fail, so it is gone rather than kept as decoration; the `with` in
    sni.py stands on not depending on an implementation detail.
    """

    def test_unset_means_no_override(self):
        sni = _fresh(MUX_DESKTOP_NOTIFIER_CTL=None)
        self.assertIsNone(sni._read_override())

    def test_missing_file_is_not_an_override(self):
        sni = _fresh(
                MUX_DESKTOP_NOTIFIER_CTL="/nonexistent/notifier-ctl")
        self.assertIsNone(sni._read_override())

    def test_set_and_readable_is_honoured(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".ctl",
                                         delete=False) as fh:
            fh.write("blocked 4\n")
            path = fh.name
        try:
            sni = _fresh(MUX_DESKTOP_NOTIFIER_CTL=path)
            self.assertEqual(sni._read_override(), ("blocked", 4))
        finally:
            os.unlink(path)


class Query(unittest.TestCase):
    """Running a source, and telling "quiet" from "could not ask".

    THE EXIT CODE IS THE CONTRACT, and ignoring it was a real bug. `mux
    agent-summary` prints `none 0` and exits 0 on a host with no agents, so
    EMPTY IS EXIT 0 and a quiet host is a genuine answer. A non-zero exit has
    no meaning of its own (it can only be the transport), so it must become
    UNKNOWN.

    The old `_query_mux` read stdout and never checked the status. A failed
    ssh produced empty output, which parsed to None, which the caller read as
    "no change", so it left the previous icon up, and an unreachable machine
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
        NOT be confused with a failure: that is the whole distinction."""
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
        host does not fail, it SLEEPS, so without a deadline the item would
        freeze on its last value indefinitely, showing a calm icon for a machine
        that fell off the network. That is the exact failure this feature exists
        to prevent, so the timeout is load-bearing, not a nicety.
        """
        sni = _fresh(MUX_DESKTOP_NOTIFIER_TIMEOUT="0.3")
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
        than the child: measured at 30s against a `sleep 30` source with the
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
        sni = _fresh(MUX_DESKTOP_NOTIFIER_TIMEOUT="0.3")
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
        # timing alone cannot see `killpg` being lost: what is lost then is the
        # grandchild, which outlives the query as a leaked process, one per
        # poll, for as long as the host stays unreachable. `-xf`, an EXACT
        # full-command-line match, not a substring one. A bare `-f` also matches
        # any shell whose own argv happens to mention the pattern (including the
        # process running this suite), which is the self-match trap this project
        # has already paid for once with `pkill -f "python -m
        # mux_desktop_notifier"`. Measured here: 3 matches loose against 1
        # exact.
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
        sni = _fresh(MUX_DESKTOP_NOTIFIER_TIMEOUT="0.3")
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
        sni = _fresh(MUX_DESKTOP_NOTIFIER_TIMEOUT="0.3")
        for argv in (["/nonexistent/x"], [self._stub("", 0)],
                     [self._stub("x", 3)]):
            self.assertIsNotNone(asyncio.run(sni._query(argv)))


class HostColour(unittest.TestCase):
    """Resolving a host's identity colours: LOCAL, once, and fail-soft.

    Run locally even for a remote host, which is the point and not a shortcut:
    the colour derives from the NAME by hashing, so this box can colour a remote
    host with nothing shared. Asking the remote would need it reachable just to
    pick a colour, so an unreachable host would lose its identity at the exact
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
        self.assertIsNone(self.sni.Tile(label="northwood")._mark)

    def test_setting_a_mark_changes_the_pixels(self):
        i = self.sni.Tile(label="northwood")
        before = i._pixmap
        i.set_mark("NWD")
        self.assertNotEqual(before, i._pixmap)

    def test_clearing_it_returns_the_original(self):
        """Detaching from your last remote must give back exactly the
        single-host tile, not a near-miss of it."""
        i = self.sni.Tile(label="northwood")
        before = i._pixmap
        i.set_mark("NWD")
        i.set_mark(None)
        self.assertEqual(before, i._pixmap)

    def test_an_unchanged_mark_does_not_repaint(self):
        """The discovery loop calls this every tick. Repainting regardless
        would emit NewIcon at the poll rate and churn the tray for nothing."""
        i = self.sni.Tile(label="northwood")
        i.set_mark("NWD")
        first = i._pixmap
        i.set_mark("NWD")
        self.assertIs(first, i._pixmap)

    def test_a_CHANGED_INK_repaints_even_when_the_mark_is_the_same(self):
        """Separate from the assertion above, and the pair of them is the
        point: comparing only the mark makes the no-repaint shortcut pin a
        host to the first colour it was ever drawn with, so a reshuffle would
        be invisible until something unrelated forced a repaint."""
        i = self.sni.Tile(label="northwood")
        i.set_mark("NWD", 0)
        first = i._pixmap
        i.set_mark("NWD", 2)
        self.assertNotEqual(first, i._pixmap)

    def test_the_ink_reaches_the_icon(self):
        """Two items, same letters, different slots. Storing the ink and never
        passing it to the renderer would leave every host one colour."""
        a, b = (self.sni.Tile(label="x") for _ in range(2))
        a.set_mark("NWD", 0)
        b.set_mark("NWD", 1)
        self.assertNotEqual(a._pixmap, b._pixmap)


class MarkPlan(unittest.TestCase):
    """Who gets a mark, and which slot: the supervisor's two rules, lifted
    out of its async loop so they can be asserted at all."""

    def setUp(self):
        import tempfile
        from mux_desktop_notifier.slots import Slots
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


    def test_TWO_PARTITIONS_ON_ONE_HOST_GET_NO_MARK(self):
        """Counted in HOSTS, not items, which is the 0.56 correction. Marking
        both would put the same three letters and the same colour on each,
        which says nothing: they ARE the same machine. The partition letter
        is what tells them apart, and the mark stays for the question it
        actually answers."""
        p = self.sni.mark_plan(["northwood:global", "northwood:work"],
                               "northwood", self.s)
        self.assertEqual(p, {"northwood:global": (None, None),
                             "northwood:work": (None, None)})

    def test_two_partitions_on_one_host_SHARE_its_identity(self):
        """With a second host present the marks come back, and both of
        northwood's items must wear the SAME mark and the SAME slot: a tray
        that gave them different colours would be saying there are three
        machines."""
        p = self.sni.mark_plan(["northwood:global", "northwood:work", "rover"],
                               "atlas", self.s)
        self.assertEqual(p["northwood:global"], p["northwood:work"])
        self.assertEqual(p["northwood:global"][0], self.sni.host_mark(
            "northwood"))
        self.assertNotEqual(p["rover"][1], p["northwood:work"][1])

    def test_the_LOCAL_host_keeps_white_across_its_partitions(self):
        """Every partition of the box you are sitting at is still that box."""
        p = self.sni.mark_plan(["northwood:global", "northwood:work", "rover"],
                               "northwood", self.s)
        self.assertIsNone(p["northwood:global"][1])
        self.assertIsNone(p["northwood:work"][1])


class PartitionNames(unittest.TestCase):
    """The item KEY and the A-Z letter: pure functions, so the rules the tray
    turns on are assertable without a bus."""

    def setUp(self):
        self.sni = _fresh()

    def test_the_solo_form_is_the_OLD_key_unchanged(self):
        """A host with one partition publishes exactly the item it always
        did: same Id, same tooltip. That is what keeps the single-partition
        case, which is every existing install, from changing at all."""
        self.assertEqual(self.sni.item_key("northwood", "global", True),
                         "northwood")
        self.assertEqual(self.sni.item_key("northwood", "work", False),
                         "northwood:work")

    def test_the_key_SPLITS_the_way_latch_targets_do(self):
        """Everything before the FIRST colon is the host, which is mux's own
        target grammar. One rule, two places that read it."""
        self.assertEqual(self.sni.host_of("northwood:work"), "northwood")
        self.assertEqual(self.sni.part_of("northwood:work"), "work")
        self.assertEqual(self.sni.host_of("northwood"), "northwood")
        self.assertIsNone(self.sni.part_of("northwood"))
        self.assertEqual(self.sni.host_of("box:a:b"), "box")
        self.assertEqual(self.sni.part_of("box:a:b"), "a:b")

    def test_ONE_PARTITION_GETS_NO_LETTER(self):
        """The same rule as the mark one level up: a letter distinguishing a
        thing from nothing is noise, and the common install must keep the icon
        it has always had."""
        self.assertEqual(self.sni.partition_letters(["global"]), {})
        self.assertEqual(self.sni.partition_letters([]), {})

    def test_A_IS_ALWAYS_THE_BASELINE(self):
        """`global` is the reserved baseline partition, so it sorts first
        whatever it is sitting beside, including names that would beat it
        alphabetically."""
        got = self.sni.partition_letters(["work", "global", "alpha"])
        self.assertEqual(got["global"], "A")
        self.assertEqual(got["alpha"], "B")
        self.assertEqual(got["work"], "C")

    def test_without_a_baseline_it_is_plain_alphabetical(self):
        """A host whose context never resolves to `global` is not an error,
        and its first partition alphabetically is simply A."""
        got = self.sni.partition_letters(["work", "alpha"])
        self.assertEqual(got, {"alpha": "A", "work": "B"})

    def test_the_letters_are_STATELESS(self):
        """Stable ordering across restarts was explicitly not required, and
        alphabetical is chosen because it needs no state: two machines drawing
        the same fleet agree without sharing anything, which the per-host
        COLOUR file has to work around."""
        a = self.sni.partition_letters(["work", "global"])
        b = self.sni.partition_letters(["global", "work"])
        self.assertEqual(a, b)

    def test_past_Z_there_is_NO_letter_rather_than_a_second_alphabet(self):
        """27 partitions is a different problem, and a tray drawing `AA` would
        be making it look solved."""
        names = [f"p{i:02d}" for i in range(30)]
        got = self.sni.partition_letters(names)
        self.assertEqual(len(got), 26)
        self.assertEqual(got["p00"], "A")
        self.assertEqual(got["p25"], "Z")
        self.assertNotIn("p26", got)


class ItemSet(unittest.TestCase):
    """Which items should exist right now: the decision the whole partition
    feature turns on, lifted out of the async loop so it can be asserted."""

    def setUp(self):
        self.sni = _fresh()

    def _feed(self, rows):
        f = self.sni.Feed(["true"])
        f.rows = rows
        f.asked = rows is not None
        return f

    def _run(self, feeds, known=None):
        known = {} if known is None else known
        got = self.sni.item_set({h: ["x"] for h in feeds},
                                {h: (f, None) for h, f in feeds.items()},
                                known)
        return got, known

    def test_one_partition_is_one_item_with_the_OLD_key(self):
        got, _k = self._run({"northwood": self._feed(
            {"global": ("idle", None)})})
        self.assertEqual(list(got), ["northwood"])
        self.assertEqual(got["northwood"][1], None)   # no partition on the key
        self.assertEqual(got["northwood"][2], None)   # and no letter

    def test_two_partitions_are_two_items_WITH_letters(self):
        got, _k = self._run({"northwood": self._feed(
            {"global": ("idle", None), "work": ("blocked", 1)})})
        self.assertEqual(sorted(got), ["northwood:global", "northwood:work"])
        self.assertEqual(got["northwood:global"][2], "A")
        self.assertEqual(got["northwood:work"][2], "B")
        self.assertEqual(got["northwood:work"][1], "work")

    def test_AN_UNREACHABLE_HOST_KEEPS_ITS_ITEMS(self):
        """The load-bearing one. The partition set lives on the other machine,
        so a failed query means "could not ask", never "it has none":
        withdrawing the items would empty the tray at the exact moment it has
        something to say, which is the entire promise of this design.
        """
        known = {}
        up = self._feed({"global": ("idle", None), "work": ("idle", None)})
        got, known = self._run({"northwood": up}, known)
        self.assertEqual(len(got), 2)
        up.rows = None                       # the network goes
        got, known = self._run({"northwood": up}, known)
        self.assertEqual(sorted(got), ["northwood:global", "northwood:work"])

    def test_a_host_that_has_NEVER_answered_publishes_nothing(self):
        """One tick only. Nothing is known about it yet, not even how many
        items it wants, and inventing one would mean withdrawing or re-keying
        it a second later."""
        got, _k = self._run({"northwood": self._feed(None)})
        self.assertEqual(got, {})

    def test_a_host_that_LOSES_a_partition_loses_its_item(self):
        """The other direction, and it has to be separate: a rule that only
        ever adds satisfies the unreachable case perfectly while the tray
        accumulates items for partitions that are long gone."""
        known = {}
        f = self._feed({"global": ("idle", None), "work": ("idle", None)})
        _got, known = self._run({"northwood": f}, known)
        f.rows = {"global": ("idle", None)}
        got, known = self._run({"northwood": f}, known)
        self.assertEqual(list(got), ["northwood"])
        # ... AND THE MEMORY FORGOT IT TOO. `known` only matters on an
        # unreachable tick, so a version that accumulated rather than
        # replacing would pass everything above and resurrect the dead
        # partition the moment the network dropped.
        f.rows = None
        got, known = self._run({"northwood": f}, known)
        self.assertEqual(list(got), ["northwood"],
                         "a partition that went away came back from `known` "
                         "when the host became unreachable")


class ParseAll(unittest.TestCase):
    """`mux agent status`: the machine contract, one round trip."""

    def setUp(self):
        self.sni = _fresh()

    @staticmethod
    def _doc(*rows, status="ok"):
        import json
        return json.dumps({"status": status, "partitions": list(rows)})

    def test_every_row_becomes_a_partition(self):
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "working", "count": 2},
            {"partition": "work", "state": "blocked", "count": 1}))
        self.assertEqual(got, {"global": ("working", 2),
                               "work": ("blocked", 1)})

    def test_the_count_arrives_as_a_NUMBER(self):
        """Most of the point of JSON over the tab-separated form: a consumer
        gets a type instead of an agreement, so nothing here re-parses it and
        nothing has to decide what a non-numeric field meant."""
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "working", "count": 2}))
        self.assertIsInstance(got["global"][1], int)

    def test_humming_is_a_KNOWN_state_not_unknown(self):
        """A newer mux reports `humming`; an indicator that does not know the
        word draws `unknown`, which is SLATE BLUE and claims the host is
        unreachable when it is perfectly fine. That skew direction is real and
        recorded at KNOWN, but it must not be this version's behaviour."""
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "humming", "count": 1}))
        self.assertEqual(got["global"][0], "humming")
        self.assertNotEqual(got["global"][0], "unknown")

    def test_an_unknown_state_word_still_becomes_unknown(self):
        """The control, and the reason the list exists at all: a feed that
        answers plausible garbage and exits 0 must not draw as calm. Measured
        once, when a mis-quoted ssh source ran the bare session picker and its
        output parsed to the state `1)`."""
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "frobnicating", "count": 1}))
        self.assertEqual(got["global"], self.sni.UNKNOWN)

    def test_idle_and_none_carry_no_count(self):
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "idle", "count": 0},
            {"partition": "work", "state": "none", "count": 0}))
        self.assertEqual(got, {"global": ("idle", None),
                               "work": ("none", None)})

    def test_a_STATE_mux_would_never_emit_is_unknown_not_dropped(self):
        """The partition is real and the feed is answering junk about it,
        which is exactly what `unknown` is for. Dropping the row would
        withdraw the item, which reads as "that partition is gone"."""
        got = self.sni.parse_all(self._doc(
            {"partition": "global", "state": "1) bootique", "count": 0}))
        self.assertEqual(got, {"global": ("unknown", None)})

    def test_a_partition_that_is_not_a_LABEL_is_DROPPED(self):
        """These names arrive from another machine and go back out inside a
        shell command, so a row that cannot be a partition name is not one,
        which stays true whatever the transport encoding is."""
        got = self.sni.parse_all(self._doc(
            {"partition": "../etc", "state": "idle", "count": 0},
            {"partition": "UP", "state": "idle", "count": 0},
            {"partition": "good", "state": "idle", "count": 0}))
        self.assertEqual(sorted(got), ["good"])

    def test_a_row_of_the_WRONG_SHAPE_is_dropped_not_guessed(self):
        got = self.sni.parse_all(self._doc(
            "not-an-object",
            {"state": "idle"},
            {"partition": "good", "state": "idle", "count": 0}))
        self.assertEqual(sorted(got), ["good"])

    def test_JUNK_IS_NONE_NOT_EMPTY(self):
        """The distinction the tab-separated form could not make. A document
        that does not parse is a host that said something other than an
        answer, and reading that as "no partitions" would withdraw its items:
emptying the tray at the exact moment it has something to say."""
        for text in ("", "\n\n", "usage: mux agent <status>\n",
                     "onlyoneword\n", "[1,2,3]", '{"status":"ok"}'):
            self.assertIsNone(self.sni.parse_all(text), repr(text))

    def test_a_REFUSAL_is_none_too(self):
        """`status` is not `ok`, so the payload is not an answer: even
        though the document parses perfectly. That is exactly what the
        symbolic status is for."""
        self.assertIsNone(self.sni.parse_all(self._doc(
            {"partition": "global", "state": "idle", "count": 0},
            status="refused")))

    def test_an_EMPTY_partition_list_is_empty_not_none(self):
        """The other half, and it has to be separate: a host where nobody is
        attached answers `[]` and that IS an answer. Collapsing it into None
        would draw `unknown` for a box that is simply quiet."""
        self.assertEqual(self.sni.parse_all(self._doc()), {})


class FeedRows(unittest.TestCase):
    """What an item reads out of its host's shared answer."""

    def setUp(self):
        self.sni = _fresh()

    def test_UNREACHABLE_is_unknown_for_every_partition(self):
        f = self.sni.Feed(["true"])
        self.assertIsNone(f.rows)
        self.assertEqual(f.row("work"), ("unknown", None))
        self.assertEqual(f.row(None), ("unknown", None))

    def test_a_partition_MISSING_from_a_good_answer_is_unknown(self):
        """Not calm. The item exists because that partition was there a moment
        ago, so its absence from a SUCCESSFUL answer is a fact nobody has
        explained, and drawing it idle would be the tray inventing one."""
        f = self.sni.Feed(["true"])
        f.rows = {"global": ("working", 2)}
        self.assertEqual(f.row("work"), ("unknown", None))

    def test_the_solo_item_reads_whichever_partition_there_is(self):
        """Its key deliberately does not name one, so that a host gaining a
        second partition RE-KEYS its item rather than mutating it."""
        f = self.sni.Feed(["true"])
        f.rows = {"work": ("blocked", 3)}
        self.assertEqual(f.row(None), ("blocked", 3))

    def test_a_solo_item_whose_host_grew_a_partition_is_unknown(self):
        """For the tick between the answer arriving and the supervisor
        re-keying. Picking the first of two would be arbitrary, and arbitrary
        here means the tile shows another partition's state under this one's
        name."""
        f = self.sni.Feed(["true"])
        f.rows = {"global": ("idle", None), "work": ("blocked", 3)}
        self.assertEqual(f.row(None), ("unknown", None))

    def test_ASKED_is_not_the_same_question_as_ANSWERED(self):
        """`rows is None` is true of a host that has not been asked AND of one
        that could not be reached, and the difference decides whether an item
        paints unknown or waits. Without it every item flashed unknown for one
        tick at startup."""
        f = self.sni.Feed(["true"])
        self.assertFalse(f.asked)


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
        self.assertEqual(self.sni.Tile(label="northwood").ident(),
                         "mux-northwood")

    def test_unlabelled_keeps_the_historical_id(self):
        self.assertEqual(self.sni.Tile().ident(), "mux-indicator")

    def test_tooltip_title_names_the_HOST(self):
        title, _body = self.sni.Tile(label="northwood").tooltip()
        self.assertEqual(title, "mux @ northwood")

    def test_two_labels_never_share_an_id(self):
        """Two items with one id is a tray that cannot tell them apart."""
        a = self.sni.Tile(label="northwood").ident()
        b = self.sni.Tile(label="northgate").ident()
        self.assertNotEqual(a, b)

    def test_unknown_tooltip_says_it_cannot_reach_the_host(self):
        """Not "all sessions idle", which is what the count-is-None branch would
        otherwise say: a calm sentence about a host we cannot see."""
        i = self.sni.Tile(state="unknown", count=None, label="northwood")
        self.assertIn("cannot reach", i.tooltip()[1])

    def test_unknown_is_not_NeedsAttention(self):
        """Only `blocked` earns attention. An unreachable host is not an
        agent waiting on you, and escalating it would cry wolf on every
        network blip."""
        i = self.sni.Tile(state="unknown", label="h")
        self.assertEqual(i.status(), "Active")




class Reconcile(unittest.TestCase):
    """The supervisor's set diff, which is what the whole daemon turns on.

    Extracted from the async loop for the same reason mark_plan was: it needs a
    bus, so nothing inside it could be asserted at all. `_supervise` and
    `_publish` held every live bug this feature has ever had (the ignored exit
    code, the hanging source, the SIGKILL AttributeError), and a 2026-09-26
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


class TraySort(unittest.TestCase):
    """The LOCAL item sorts first.

    Most trays alpha-sort by Id and offer no way to say otherwise, so position
    has to be bought in the string. The box you are sitting at is the one you
    look at most, and it should not wander into the middle of the row as you
    latch and detach elsewhere.
    """

    def setUp(self):
        self.sni = _fresh()

    def test_local_gets_the_sort_prefix(self):
        self.assertEqual(self.sni.item_id("northwood", local=True),
                         "mux--northwood")

    def test_a_remote_does_not(self):
        self.assertEqual(self.sni.item_id("northwood"), "mux-northwood")

    def test_unlabelled_keeps_the_historical_id(self):
        self.assertEqual(self.sni.item_id(None), "mux-indicator")
        self.assertEqual(self.sni.item_id("", local=True), "mux-indicator")

    def test_the_mux_prefix_SURVIVES_the_sort_prefix(self):
        """A bar's `order` array is keyed on `mux-`. Buying sort position by
        breaking that would trade one ordering problem for another."""
        for lab, loc in (("northwood", True), ("rover", False)):
            self.assertTrue(self.sni.item_id(lab, loc).startswith("mux-"))

    def test_LOCAL_SORTS_FIRST_against_awkward_hostnames(self):
        """The assertion that picked the character. `_` and a leading digit
        both look right against ordinary lowercase names and both lose: `_`
        (0x5F) sorts after `7bravo` and after every capitalised name, and a
        digit loses to a lower digit. `-` is 0x2D, below digits, uppercase and
        lowercase alike, so it beats any legal hostname."""
        remotes = ["Atlas", "7bravo", "rover", "northgate", "ZZZ", "0a"]
        ids = [self.sni.item_id(h) for h in remotes]
        me = self.sni.item_id("northwood", local=True)
        self.assertEqual(sorted(ids + [me])[0], me)

    def test_the_item_reports_it_through_Id(self):
        """Separate from item_id: the pure function can be perfect while the
        property ignores it, and Id is what a tray host actually reads."""
        loc = self.sni.Tile(label="northwood", local=True)
        rem = self.sni.Tile(label="northwood")
        self.assertEqual(loc.ident(), "mux--northwood")
        self.assertEqual(rem.ident(), "mux-northwood")

    def test_an_item_is_remote_unless_told_otherwise(self):
        """The default must not hand the sort prefix to a remote host, which
        would put a random box first and defeat the whole thing."""
        self.assertFalse(self.sni.Tile(label="rover")._local)


class Watch(unittest.TestCase):
    """The per-item repaint loop: what it repaints, and how often.

    Tested as the real loop rather than through an extraction, because the loop
    IS the rule: there is nothing left once you lift the decision out of it.
    Driven with a tiny POLL and cancelled, so it runs in milliseconds.

    THE ITEM NO LONGER POLLS. Its host's Feed does, once per tick for every
    partition at once, and the item waits on it and reads its own row, so
    these drive a real Feed over a stub source, which is also what proves the
    two halves fit together.
    """

    def _source(self, body):
        import stat
        import tempfile
        fd, path = tempfile.mkstemp(prefix="muxwatch", suffix=".sh")
        with os.fdopen(fd, "w") as fh:
            fh.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.addCleanup(os.unlink, path)
        return path

    class _Item:
        def __init__(self):
            self.calls = []

        def set(self, state, count):
            self.calls.append((state, count))

    def _spin(self, sni, item, argv, seconds=0.25, part=None):
        """Runs a Feed and one watcher briefly, then cancels both. stdout is
        swallowed: the loop logs every change by design, and a suite that
        prints is a suite whose real output you stop reading."""
        import contextlib
        import io

        async def go():
            feed = sni.Feed(argv)
            pt = asyncio.ensure_future(feed.poll())
            task = asyncio.ensure_future(sni._watch(item, feed, part, "test"))
            await asyncio.sleep(seconds)
            for t in (task, pt):
                t.cancel()
                try:
                    await t
                except asyncio.CancelledError:
                    pass
        with contextlib.redirect_stdout(io.StringIO()):
            asyncio.run(go())

    def test_AN_UNCHANGED_VALUE_IS_NOT_REPAINTED(self):
        """The loop polls every POLL seconds forever. Repainting regardless
        would emit NewIcon at the poll rate for every host, which churns the
        tray and defeats the blink that is supposed to mean "look at me"."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_POLL="0.01",
                     MUX_DESKTOP_NOTIFIER_CTL=None)
        item = self._Item()
        self._spin(sni, item, [self._source(
            'printf \'{"status":"ok","partitions":'
            '[{"partition":"global","state":"working","count":2}]}\\n\'')])
        self.assertEqual(item.calls, [("working", 2)],
                         f"repainted {len(item.calls)} times for one value")

    def test_a_CHANGED_value_is_repainted(self):
        """The other half, and it has to be asserted separately: a loop that
        never repaints at all satisfies the test above perfectly."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_POLL="0.01",
                     MUX_DESKTOP_NOTIFIER_CTL=None)
        import tempfile
        counter = tempfile.mktemp(prefix="muxwatchn")
        self.addCleanup(lambda: os.path.exists(counter) and os.unlink(counter))
        src = self._source(
            f'n=$(cat {counter} 2>/dev/null || echo 0)\n'
            f'echo $((n + 1)) >{counter}\n'
            f'p() {{ printf \'{{"status":"ok","partitions":'
            f'[{{"partition":"global","state":"%s","count":%s}}]}}\\n\' '
            f'"$1" "$2"; }}\n'
            f'if [ "$n" -lt 2 ]; then p working 1\n'
            f'else p blocked 3; fi')
        item = self._Item()
        self._spin(sni, item, [src])
        self.assertIn(("working", 1), item.calls)
        self.assertIn(("blocked", 3), item.calls)

    def test_an_UNREACHABLE_source_becomes_unknown_here_too(self):
        """End to end through the loop, not just _query: the path from a failed
        transport to a repainted icon is what the feature promises."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_POLL="0.01",
                     MUX_DESKTOP_NOTIFIER_CTL=None)
        item = self._Item()
        self._spin(sni, item, ["/nonexistent/mux-for-a-test"])
        self.assertEqual(item.calls, [("unknown", None)])

    def test_the_OVERRIDE_wins_over_the_source(self):
        """The override exists to pin a value for testing. A source that
        disagreed and won would make it useless and very confusing."""
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".ctl",
                                         delete=False) as fh:
            fh.write("blocked 9\n")
            path = fh.name
        self.addCleanup(os.unlink, path)
        sni = _fresh(MUX_DESKTOP_NOTIFIER_POLL="0.01",
                     MUX_DESKTOP_NOTIFIER_CTL=path)
        item = self._Item()
        self._spin(sni, item, [self._source(
            'printf \'{"status":"ok","partitions":'
            '[{"partition":"global","state":"idle","count":0}]}\\n\'')])
        self.assertEqual(item.calls, [("blocked", 9)])


class Entry(unittest.TestCase):
    """__main__: the daemon's front door, previously 0% covered."""

    def test_ctrl_c_exits_cleanly(self):
        """A KeyboardInterrupt escaping asyncio.run would print a traceback on
        every Ctrl-C and exit non-zero, which for a systemd --user unit reads
        as a crash and triggers the restart policy."""
        import mux_desktop_notifier.__main__ as m

        async def boom():
            raise KeyboardInterrupt
        old = m.run
        m.run = boom
        try:
            m.main([])        # must simply return
        finally:
            m.run = old

    def test_a_real_error_is_NOT_swallowed(self):
        """Only KeyboardInterrupt is caught. Catching more would turn a broken
        daemon into a silently exiting one, which systemd would report as a
        clean stop and nobody would investigate."""
        import mux_desktop_notifier.__main__ as m

        async def boom():
            raise RuntimeError("the bus went away")
        old = m.run
        m.run = boom
        try:
            with self.assertRaises(RuntimeError):
                m.main([])
        finally:
            m.run = old


class Blink(unittest.TestCase):
    """set() and the cursor blink: the "look at me" on a state change.

    Uncovered until 2026-09-26. The blink is the only motion the tray ever
    makes, and every way it can fail is quiet: it stops blinking, or it never
    stops, or it settles with the cursor hidden and the icon looks subtly wrong
    forever after.
    """

    def _item(self, sni, **kw):
        return sni.Tile(label="northwood", **kw)

    def test_set_updates_the_state_and_repaints(self):
        sni = _fresh(MUX_DESKTOP_NOTIFIER_BLINK="1",
                     MUX_DESKTOP_NOTIFIER_BLINK_MS="1")

        async def go():
            i = self._item(sni)
            before = i._pixmap
            i.set("blocked", 4)
            self.assertEqual((i._state, i._count), ("blocked", 4))
            self.assertNotEqual(before, i._pixmap)
            i._blink.cancel()
        asyncio.run(go())

    def test_blocked_becomes_NeedsAttention(self):
        """The status a tray host reads to decide whether to highlight the
        item. Getting it wrong makes the loudest state look ordinary."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_BLINK="1",
                     MUX_DESKTOP_NOTIFIER_BLINK_MS="1")

        async def go():
            i = self._item(sni)
            i.set("blocked", 1)
            self.assertEqual(i.status(), "NeedsAttention")
            i._blink.cancel()
            i.set("idle", None)
            self.assertEqual(i.status(), "Active")
            i._blink.cancel()
        asyncio.run(go())

    def test_THE_BLINK_SETTLES_CURSOR_ON(self):
        """It runs a fixed number of frames and stops with the cursor SHOWING.
        Finishing on the hidden frame would leave that host's icon permanently
        missing its cursor, which looks like a rendering bug rather than the
        end of an animation."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_BLINK="2",
                     MUX_DESKTOP_NOTIFIER_BLINK_MS="1")

        async def go():
            i = self._item(sni)
            i.set("working", 2)
            await i._blink
            self.assertEqual(
                i._pixmap,
                sni.icon_pixmap("working", 2, cursor=True, host=i._host,
                                mark=i._mark, ink=i._ink),
                "the blink finished on the cursor-OFF frame")
        asyncio.run(go())

    def test_A_CANCELLED_BLINK_ALSO_SETTLES_CURSOR_ON(self):
        """A second change cancels the first blink mid-frame, and that is the
        common case, not the rare one: a busy agent changes state faster than
        the animation runs. Cancelling on the hidden frame without restoring
        would leave the cursor off until something else repainted."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_BLINK="50",
                     MUX_DESKTOP_NOTIFIER_BLINK_MS="1")

        async def go():
            i = self._item(sni)
            i.set("working", 2)
            await asyncio.sleep(0.01)      # land mid-animation
            i._blink.cancel()
            try:
                await i._blink
            except asyncio.CancelledError:
                pass
            self.assertEqual(
                i._pixmap,
                sni.icon_pixmap("working", 2, cursor=True, host=i._host,
                                mark=i._mark, ink=i._ink),
                "a cancelled blink left the cursor hidden")
        asyncio.run(go())

    def test_a_SECOND_set_does_not_stack_blinks(self):
        """Two overlapping animations would fight over the same pixmap and the
        icon would flicker at twice the rate, then keep flickering after the
        newer one finished."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_BLINK="50",
                     MUX_DESKTOP_NOTIFIER_BLINK_MS="1")

        async def go():
            i = self._item(sni)
            i.set("working", 2)
            first = i._blink
            i.set("blocked", 1)
            self.assertIsNot(first, i._blink)
            await asyncio.sleep(0)
            self.assertTrue(first.cancelled() or first.done(),
                            "the previous blink was left running")
            i._blink.cancel()
        asyncio.run(go())


class Activate(unittest.TestCase):
    """What a click actually runs.

    Two halves, and the split is the design: mux switches the host's client,
    the integrator raises the window. Asserted by capturing the argv rather
    than by running anything: what matters is WHICH command goes WHERE.
    """

    def setUp(self):
        self.sni = _fresh()
        self.fired = []

        async def _fake(argv, what):
            self.fired.append((list(argv), what))
        self.sni._fire = _fake
        self._env = os.environ.get("MUX_DESKTOP_NOTIFIER_ACTIVATE")
        os.environ.pop("MUX_DESKTOP_NOTIFIER_ACTIVATE", None)

    def tearDown(self):
        if self._env is None:
            os.environ.pop("MUX_DESKTOP_NOTIFIER_ACTIVATE", None)
        else:
            os.environ["MUX_DESKTOP_NOTIFIER_ACTIVATE"] = self._env

    def test_the_LOCAL_item_runs_mux_directly(self):
        """No transport for our own box: it is the daemon's own machine, not
        a host we reach over anything."""
        asyncio.run(self.sni.activate(self.sni.local_label()))
        argv, _what = self.fired[0]
        self.assertIn("next-blocked", argv)
        self.assertNotIn("ssh", " ".join(argv))

    def test_a_REMOTE_item_goes_over_the_transport(self):
        """And asks for next-blocked, not agent-summary. The same transport
        carries both, so the COMMAND is the only thing distinguishing a click
        from a poll: send the wrong one and every click silently re-reads
        state it already had."""
        os.environ["MUX_DESKTOP_NOTIFIER_TRANSPORT"] = "ssh %h %q"
        try:
            asyncio.run(self.sni.activate("someotherbox"))
        finally:
            os.environ.pop("MUX_DESKTOP_NOTIFIER_TRANSPORT", None)
        argv, _what = self.fired[0]
        self.assertEqual(argv[0], "ssh")
        self.assertIn("someotherbox", argv)
        self.assertIn("mux next-blocked", " ".join(argv))

    def test_NO_HOOK_MEANS_NO_SECOND_COMMAND(self):
        """Unset is the third answer, not a missing one. A click still does
        the half mux owns; nothing reaches for a compositor uninvited."""
        asyncio.run(self.sni.activate(self.sni.local_label()))
        self.assertEqual(len(self.fired), 1,
                         f"something ran besides the switch: {self.fired}")

    def test_the_hook_RUNS_AFTER_and_is_given_the_label(self):
        """Order matters: switching first means the window you are raising
        already shows the right session by the time it comes forward."""
        os.environ["MUX_DESKTOP_NOTIFIER_ACTIVATE"] = "focus-window --raise"
        asyncio.run(self.sni.activate("boxname"))
        self.assertEqual(len(self.fired), 2)
        (_sw, _), (hook, _w) = self.fired
        self.assertEqual(hook, ["focus-window", "--raise", "boxname"])

    def test_the_hook_is_SPLIT_not_shelled(self):
        """A command line in config, not a script. Handing it to `sh -c`
        would make a label containing a space an injection rather than an
        argument."""
        os.environ["MUX_DESKTOP_NOTIFIER_ACTIVATE"] = "focus-window"
        asyncio.run(self.sni.activate("a box"))
        hook, _w = self.fired[1]
        self.assertEqual(hook, ["focus-window", "a box"])


class StreamingFeed(unittest.TestCase):
    """A Feed fed by `mux agent stream` rather than by repeated asking.

    THE POINT IS NOT LATENCY. Polling opened a connection to every watched
    host every few seconds; a stream moves the polling ON to the watched box
    and sends only CHANGES. What it costs is the one signal polling got free:
    a non-zero exit could only be the transport, so `unknown` was trustworthy,
    and a stream that simply stops speaking has no such signal. Hence the
    producer's heartbeat and this reader's staleness rule, which these tests
    are mostly about.
    """

    def _feed(self, sni, argv):
        f = sni.Feed(["unused"], stream_argv=argv)
        return f

    def test_an_answer_sets_the_rows(self):
        sni = _fresh()
        f = self._feed(sni, ["unused"])
        line = (b'{"status":"ok","partitions":'
                b'[{"partition":"global","state":"blocked","count":2}]}\n')
        self.assertTrue(f._ingest(line), "an answer must wake the items")
        self.assertEqual(f.rows, {"global": ("blocked", 2)})

    def test_a_HEARTBEAT_is_not_an_answer(self):
        """The load-bearing one. A heartbeat carries no `partitions`, so
        `parse_all` yields None for it, and treating that as an answer would
        blank every item on this host on every keepalive: the calm-host signal
        turned into a flashing unknown, several times a minute, for ever."""
        sni = _fresh()
        f = self._feed(sni, ["unused"])
        f._ingest(b'{"status":"ok","partitions":'
                  b'[{"partition":"global","state":"idle","count":0}]}\n')
        before = f.rows
        self.assertFalse(f._ingest(b'{"status":"ok","heartbeat":true}\n'),
                         "a heartbeat must not be reported as an answer")
        self.assertEqual(f.rows, before,
                         "a heartbeat changed the rows")

    def test_JUNK_makes_the_host_unknown(self):
        """And the other direction, which matters just as much: a feed
        emitting junk fast would never go stale, so it would hold its last
        good value for ever. That is the original sin of this indicator, an
        unreachable box showing whatever it last said."""
        sni = _fresh()
        f = self._feed(sni, ["unused"])
        f._ingest(b'{"status":"ok","partitions":'
                  b'[{"partition":"global","state":"idle","count":0}]}\n')
        self.assertTrue(f._ingest(b'not json at all\n'))
        self.assertIsNone(f.rows)

    def test_a_refusal_is_also_unknown(self):
        sni = _fresh()
        f = self._feed(sni, ["unused"])
        self.assertTrue(f._ingest(b'{"status":"refused","message":"no"}\n'))
        self.assertIsNone(f.rows)

    def test_watch_READS_a_real_stream(self):
        """End to end against a real subprocess: two documents, then exit."""
        sni = _fresh()
        sni.RESPAWN = 3600          # do not respawn inside the test
        doc = ('{"status":"ok","partitions":'
               '[{"partition":"global","state":"%s","count":%d}]}')
        script = ("printf '%s\\n'; sleep 0.2; printf '%s\\n'; sleep 5"
                  % (doc % ("idle", 0), doc % ("blocked", 3)))
        f = self._feed(sni, ["sh", "-c", script])

        async def drive():
            t = asyncio.get_event_loop().create_task(f.watch())
            await asyncio.sleep(1.0)
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
        asyncio.run(drive())
        self.assertEqual(f.rows, {"global": ("blocked", 3)},
                         "the LAST document should be the live one")

    def test_a_SILENT_stream_becomes_unknown(self):
        """The heartbeat's whole reason. A source that connects and then says
        nothing is indistinguishable from a calm one without a deadline, and
        this package has measured both failures it hides: a blackholed port,
        and a responsive peer making no progress for 342 seconds."""
        sni = _fresh()
        sni.STALE = 0.5
        sni.RESPAWN = 3600
        doc = ('{"status":"ok","partitions":'
               '[{"partition":"global","state":"idle","count":0}]}')
        f = self._feed(sni, ["sh", "-c", "printf '%s\\n'; sleep 30" % doc])

        async def drive():
            t = asyncio.get_event_loop().create_task(f.watch())
            await asyncio.sleep(0.2)
            mid = f.rows
            await asyncio.sleep(1.2)
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
            return mid
        mid = asyncio.run(drive())
        # `idle` carries no count by contract (parse_all normalises it away),
        # so None here is the right answer and not a missing field.
        self.assertEqual(mid, {"global": ("idle", None)},
                         "precondition: the first document was never read, so "
                         "the staleness assertion proves nothing")
        self.assertIsNone(f.rows,
                          "a stream that went silent past the staleness "
                          "deadline is still being believed")

    def test_a_stream_that_DIES_becomes_unknown(self):
        sni = _fresh()
        sni.RESPAWN = 3600
        doc = ('{"status":"ok","partitions":'
               '[{"partition":"global","state":"idle","count":0}]}')
        f = self._feed(sni, ["sh", "-c", "printf '%s\\n'" % doc])

        async def drive():
            t = asyncio.get_event_loop().create_task(f.watch())
            await asyncio.sleep(0.6)
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
        asyncio.run(drive())
        self.assertIsNone(f.rows,
                          "the stream exited and its last answer is still "
                          "on screen, which is the stale-icon bug")

    def test_the_staleness_deadline_EXCEEDS_the_producers_heartbeat(self):
        """A cross-process contract, and the kind that is only wrong once in
        production. `mux agent stream` beats every 15s by default; a deadline
        at or below that declares a perfectly healthy feed dead."""
        sni = _fresh()
        self.assertGreater(sni.STALE, 15.0)

    def test_a_source_that_CANNOT_stream_falls_back_to_POLLING(self):
        """The mixed-fleet case, and the reason `watch` is allowed to return.
        A remote running a mux too old to know the verb answers one line of
        `{"status":"usage"}` and exits 2. Without a downgrade that host sits
        `unknown` for ever while being perfectly reachable, respawning a
        doomed stream every few seconds: plausible, wrong and silent.

        RESPAWN is enormous here on purpose, so a `watch` that loops instead
        of returning hangs and is caught by the timeout rather than passing.
        """
        sni = _fresh()
        sni.RESPAWN = 3600
        doc = ('{"status":"ok","partitions":'
               '[{"partition":"global","state":"blocked","count":2}]}')
        f = sni.Feed(["sh", "-c", "printf '%s\\n'" % doc],
                     stream_argv=["sh", "-c",
                                  "printf '{\"status\":\"usage\"}\\n'; exit 2"])

        async def drive():
            await asyncio.wait_for(f.watch(), 5)
        asyncio.run(drive())
        self.assertEqual(f.rows, {"global": ("blocked", 2)},
                         "the fallback poll's answer must be on screen: "
                         "returning without it leaves the host blank for a "
                         "whole poll interval")

    def test_an_UNREACHABLE_host_KEEPS_trying_the_stream(self):
        """The other direction, and it is a different bug, so it is a
        different assertion: a host that is simply down ALSO fails to stream
        without answering, and downgrading it would spend the feature
        permanently on a network blip. The discriminator is that an
        unreachable host answers neither channel, so the poll is what tells
        the two apart rather than any timing rule.
        """
        sni = _fresh()
        sni.RESPAWN = 0.05
        f = sni.Feed(["sh", "-c", "exit 1"],
                     stream_argv=["sh", "-c", "exit 1"])

        async def drive():
            t = asyncio.get_event_loop().create_task(f.watch())
            await asyncio.sleep(0.5)
            gave_up = t.done()
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
            return gave_up
        self.assertFalse(asyncio.run(drive()),
                         "a host that answers NEITHER channel was downgraded "
                         "to polling, so a blip costs it streaming for the "
                         "rest of the daemon's life")
        self.assertIsNone(f.rows, "an unreachable host must read unknown")


class Toasts(unittest.TestCase):
    """The daemon raises every banner now, local and remote alike.

    WHY IT MOVED AT ALL. `mux-agent-state-emit` raised it on the box the AGENT
    runs on, which is the one machine that may have nobody sitting at it:
    every blocked latched session has been popping a toast on a remote desktop
    for as long as latch has existed. A hook cannot reach the box the human is
    at, so the fix was never available there.

    THE DECISION IS STILL THE WATCHED BOX'S, and these tests are only about
    presentation: wording, and when a banner stops being true.
    """

    class Bus:
        """A notification service that records rather than draws."""

        def __init__(self, fail=False):
            self.calls = []
            self.closed = []
            self._next = 100
            self._fail = fail

        async def introspect(self, *a):
            return None

        def get_proxy_object(self, *a):
            return self

        def get_interface(self, *a):
            return self

        async def call_notify(self, app, replaces, icon, summary, body,
                              actions, hints, timeout):
            if self._fail:
                raise RuntimeError("no notification daemon")
            self.calls.append((app, replaces, summary, body))
            self._next += 1
            return self._next

        async def call_close_notification(self, nid):
            self.closed.append(nid)

    def _toaster(self, **kw):
        sni = _fresh()
        bus = self.Bus(**kw)
        return sni, bus, sni.Toaster(bus)

    def test_a_blocked_announcement_names_the_session(self):
        """The session name is the whole point of carrying sessions on the
        wire: a banner that names only the partition tells you a box needs
        you and not which agent."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        self.assertEqual(len(bus.calls), 1)
        self.assertIn("api", bus.calls[0][2])
        self.assertIn("needs you", bus.calls[0][2])

    def test_a_finished_announcement_differs_from_blocked(self):
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "finished"))
        self.assertIn("finished", bus.calls[0][2])
        self.assertNotIn("needs you", bus.calls[0][2])

    def test_a_REMOTE_banner_names_the_host(self):
        """emit could never say which machine, because it only ever ran on
        one. Two boxes running a session of the same name would otherwise
        produce identical banners, which is the lesson the tray spent two
        releases learning about colour."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("northwood", "global", "api", "finished",
                               local=False))
        self.assertIn("northwood", bus.calls[0][3])

    def test_a_LOCAL_banner_does_not(self):
        """The control, and the reason it is a separate case: a banner that
        said "on this-box" every time would be noise on the common path."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("here", "global", "api", "finished",
                               local=True))
        self.assertNotIn("here", bus.calls[0][3])

    def test_a_SECOND_announcement_replaces_the_first(self):
        """A session that blocks, is answered and blocks again should leave
        ONE banner rather than a column of them. The id we already hold is
        passed as `replaces`, which is what the freedesktop spec is for."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        first = bus.calls[0]
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        self.assertEqual(first[1], 0, "the first must not replace anything")
        self.assertNotEqual(bus.calls[1][1], 0,
                            "the second must replace the first, not stack")

    def test_a_banner_is_WITHDRAWN_when_it_stops_being_true(self):
        """The half emit did by carrying an id in the record. A `blocked`
        banner announces a prompt that is waiting; once that pane is not
        blocked the prompt has been answered and the banner is a lie."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        nid = bus.calls[0]
        asyncio.run(t.sync("boxa", {"global": {"api": "working"}}))
        self.assertEqual(len(bus.closed), 1, f"not withdrawn (raised {nid})")

    def test_a_banner_SURVIVES_while_it_is_still_true(self):
        """The control, and it is the load-bearing direction: a sync that
        closed everything would pass any count-based check while making every
        banner vanish on the next answer, which is a prompt you never see."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        asyncio.run(t.sync("boxa", {"global": {"api": "blocked"}}))
        self.assertEqual(bus.closed, [],
                         "a still-blocked session had its banner withdrawn")

    def test_a_VANISHED_session_has_its_banner_withdrawn(self):
        """Its pane is gone, so the prompt it announced cannot still be
        waiting. Without this a killed session leaves a banner asking for
        input that nothing can receive."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        asyncio.run(t.sync("boxa", {"global": {}}))
        self.assertEqual(len(bus.closed), 1)

    def test_a_finished_banner_goes_when_the_turn_STARTS_again(self):
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "finished"))
        asyncio.run(t.sync("boxa", {"global": {"api": "humming"}}))
        self.assertEqual(bus.closed, [],
                         "humming is still the turn having ended")
        asyncio.run(t.sync("boxa", {"global": {"api": "working"}}))
        self.assertEqual(len(bus.closed), 1)

    def test_another_HOST_is_not_touched(self):
        """`stale` is asked per host because a feed only ever answers for its
        own. Sweeping every key on one host's answer would withdraw a banner
        for a box that has said nothing."""
        sni, bus, t = self._toaster()
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        asyncio.run(t.announce("boxb", "global", "api", "blocked"))
        asyncio.run(t.sync("boxa", {"global": {}}))
        self.assertEqual(len(bus.closed), 1,
                         "one host's answer withdrew another host's banner")

    def test_TOASTS_off_raises_nothing(self):
        sni = _fresh()
        bus = self.Bus()
        t = sni.Toaster(bus, enabled=False)
        asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        self.assertEqual(bus.calls, [])

    def test_a_desktop_with_no_notification_daemon_is_not_fatal(self):
        """The tray is the persistent half of this signal and goes on being
        right. Said once rather than swallowed, because silence here is
        indistinguishable from a stream that announced nothing."""
        sni, bus, t = self._toaster(fail=True)
        got = asyncio.run(t.announce("boxa", "global", "api", "blocked"))
        self.assertIsNone(got)


class Surfaces(unittest.TestCase):
    """The two switches, and that each leaves the other alone."""

    def test_both_default_ON(self):
        sni = _fresh()
        self.assertEqual(sni.flags([])[:2], (True, True))

    def test_each_flag_turns_off_only_its_own(self):
        sni = _fresh()
        self.assertEqual(sni.flags(["--no-tray"])[:2], (False, True))
        self.assertEqual(sni.flags(["--no-toasts"])[:2], (True, False))

    def test_both_can_go(self):
        sni = _fresh()
        self.assertEqual(sni.flags(["--no-tray", "--no-toasts"])[:2],
                         (False, False))

    def test_a_flag_WINS_over_the_environment(self):
        """A flag is passed by whoever launched this process and the
        environment is inherited from whatever launched it, so the flag is
        the more specific of the two."""
        sni = _fresh(MUX_DESKTOP_NOTIFIER_TOASTS="0")
        self.assertEqual(sni.flags([])[1], False, "the env must be read")
        self.assertEqual(sni.flags(["--toasts"])[1], True,
                         "a flag must override the inherited environment")

    def test_an_UNKNOWN_argument_is_refused(self):
        """Never ignored. `setup.sh install PREFIX=/var/tmp/x` installed to
        the REAL prefix and said it worked, because the argument was never
        read; a daemon that ignored `--no-toasts` would be the same defect
        with a banner instead of a prefix."""
        sni = _fresh()
        with self.assertRaises(SystemExit):
            sni.flags(["--no-tost"])


class Ignored(unittest.TestCase):
    """Partitions this daemon says nothing about, on either surface.

    THE DEMO IS WHY IT SHIPS NON-EMPTY. `mux demo` drives four pretend agents
    through the REAL machinery for ever, so it produces real transitions, and
    without a filter a demo fills the notification daemon with news about
    sessions that do not exist. That used to be suppressed by an env pair the
    demo exported into the hook it invoked, and that mechanism is structurally
    gone now that the raiser is a separate long-lived process no demo can
    reach: there is no variable a demo can set that this daemon reads.

    A FILTER RATHER THAN A HARDCODED REFUSAL, which is the point: validating
    the name instead (a demo socket contains a dot, so it is not a DNS label)
    would have been one line and could never be opted OUT of. Somebody
    watching the demo and wanting to see its banners has to be able to.
    """

    def _doc(self, part, state="blocked", session="api"):
        return (f'{{"status":"ok","partitions":[{{"partition":"{part}",'
                f'"state":"{state}","count":1,"sessions":'
                f'[{{"session":"{session}","state":"{state}"}}]}}]}}\n'
                ).encode()

    def _ann(self, part, session="api", kind="blocked"):
        return (f'{{"status":"ok","announce":{{"partition":"{part}",'
                f'"session":"{session}","kind":"{kind}"}}}}\n').encode()

    def test_an_ignored_partition_announces_nothing(self):
        sni = _fresh()
        sni.IGNORE = frozenset(["mux.demo"])
        f = sni.Feed(["unused"], stream_argv=["unused"])
        f._ingest(self._ann("mux.demo"))
        self.assertEqual(f.pending, [],
                         "an ignored partition reached the toaster")

    def test_a_WATCHED_partition_still_does(self):
        """The control, and it is what makes the silence the filter's doing
        rather than an ingest that drops every announcement."""
        sni = _fresh()
        sni.IGNORE = frozenset(["mux.demo"])
        f = sni.Feed(["unused"], stream_argv=["unused"])
        f._ingest(self._ann("global"))
        self.assertEqual(f.pending, [("global", "api", "blocked")])

    def test_an_ignored_partition_gets_no_tray_item_either(self):
        """`ignore` naming only the banners would be a filter whose name
        lies. `parse_all`'s DNS-label rule already drops a demo namespace for
        the tray by accident; this does it on purpose, and does it for a real
        partition somebody wants hidden, which that rule never could."""
        sni = _fresh()
        sni.IGNORE = frozenset(["work"])
        f = sni.Feed(["unused"], stream_argv=["unused"])
        f._ingest(self._doc("work"))
        self.assertEqual(f.rows, {}, "an ignored partition kept its rows")
        self.assertEqual(f.sessions.get("work"), None)

    def test_ignoring_is_not_the_same_as_UNREACHABLE(self):
        """The distinction the whole indicator rests on: `{}` is "it answered
        and has nothing for you", `None` is "could not ask". Collapsing them
        would paint an ignored partition's host `unknown`, which is the one
        reading that must never be invented."""
        sni = _fresh()
        sni.IGNORE = frozenset(["work"])
        f = sni.Feed(["unused"], stream_argv=["unused"])
        f._ingest(self._doc("work"))
        self.assertIsNotNone(f.rows,
                             "an ignored partition made its host unknown")

    def test_the_default_ignores_the_demo(self):
        sni = _fresh()
        self.assertIn("mux.demo", sni.flags([])[2])

    def test_ignore_none_turns_the_filter_OFF(self):
        """How somebody watching the demo asks to see its banners. A word
        rather than an empty value, for the reason `latch-fallback none`
        already exists: a key present but blank reads identically to a key
        absent, so "ignore nothing" needs saying."""
        sni = _fresh()
        self.assertEqual(sni.flags(["--ignore", "none"])[2], frozenset())

    def test_ignore_ADDS_to_what_was_resolved(self):
        sni = _fresh()
        got = sni.flags(["--ignore", "work"])[2]
        self.assertIn("work", got)
        self.assertIn("mux.demo", got,
                      "--ignore replaced the resolved set instead of adding")

    def test_a_dangling_ignore_is_refused(self):
        """`--ignore` with nothing after it would otherwise silently ignore
        nothing, which is the shape `setup.sh install PREFIX=...` taught this
        repo to refuse: an argument that reads as configuration and does
        nothing is worse than one that errors."""
        sni = _fresh()
        with self.assertRaises(SystemExit):
            sni.flags(["--ignore"])


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
