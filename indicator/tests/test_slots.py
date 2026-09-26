"""Palette slot assignment: seeded by name, bumped on collision, then sticky.

Each of those three is tested on its own, because each exists to fix a problem
the other two do not. A single "two hosts get different colours" assertion
passes on a pure first-come rule, on a pure derived rule, and on this one, so
it would tell us nothing about which we shipped.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mux_indicator.slots import Slots, state_dir, store_path


class TestSeeding(unittest.TestCase):
    """DERIVED FROM THE NAME, so a host is the same colour on every box."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = os.path.join(self.d, "indicator-slots")

    def test_the_seed_is_stable_across_instances(self):
        """The whole point: a fresh daemon, a fresh box, the same answer. A
        salted hash (Python's own `hash()`) would pass a single-process test
        and reassign every slot on restart."""
        a = Slots(5, self.p).preferred("manifold")
        b = Slots(5, os.path.join(self.d, "other")).preferred("manifold")
        self.assertEqual(a, b)

    def test_the_seed_is_NOT_just_a_constant(self):
        """A seed returning 0 for everything would satisfy "stable" perfectly
        and make every host collide, which the bump would then paper over."""
        names = ["manifold", "manifestor", "rover", "atlas", "nimbus",
                 "charon-box", "vicus", "helios"]
        seen = {Slots(5, self.p).preferred(n) for n in names}
        self.assertGreater(len(seen), 1)

    def test_a_free_preferred_slot_is_ACTUALLY_TAKEN(self):
        """Seeding must reach the answer, not merely be computed. A `slot()`
        that ignored `preferred()` and counted upward from zero would pass
        every distinctness test in this file."""
        s = Slots(5, self.p)
        self.assertEqual(s.slot("manifold"), s.preferred("manifold"))

    def test_the_slot_is_inside_the_palette(self):
        for n in ("a", "manifold", "x" * 200, "", "host with spaces"):
            self.assertIn(Slots(5, self.p).slot(n), range(5))


class TestCollision(unittest.TestCase):
    """BUMPED, because a derived rule alone cannot promise distinctness."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = os.path.join(self.d, "indicator-slots")

    def _colliding_pair(self, width):
        """Two real names that seed to the same slot, found rather than
        assumed: hand-picking a pair would silently stop colliding the day the
        seed changes, and the test would then prove nothing."""
        s = Slots(width, self.p)
        seen = {}
        for i in range(500):
            n = f"host{i}"
            k = s.preferred(n)
            if k in seen:
                return seen[k], n
            seen[k] = n
        self.fail("no colliding pair in 500 names")

    def test_a_collision_is_bumped_not_shared(self):
        a, b = self._colliding_pair(5)
        s = Slots(5, self.p)
        self.assertEqual(s.preferred(a), s.preferred(b))   # same seed
        self.assertNotEqual(s.slot(a), s.slot(b))          # different slot

    def test_the_bump_does_not_move_the_INCUMBENT(self):
        """The host that was there first keeps what it had. Resolving a
        collision by moving both is how a colour changes under a machine you
        were not even touching."""
        a, b = self._colliding_pair(5)
        s = Slots(5, self.p)
        first = s.slot(a)
        s.slot(b)
        self.assertEqual(s.slot(a), first)

    def test_more_hosts_than_slots_still_answers(self):
        """Past the palette it must degrade, never raise. Colour is a hint and
        the letters stay unique, so a shared hue is the right answer."""
        s = Slots(5, self.p)
        got = [s.slot(f"h{i}") for i in range(12)]
        self.assertEqual(len(got), 12)
        for g in got:
            self.assertIn(g, range(5))


class TestSticky(unittest.TestCase):
    """PERSISTED, so an assignment outlives the daemon and the live set."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = os.path.join(self.d, "indicator-slots")

    def test_an_assignment_survives_a_restart(self):
        first = Slots(5, self.p)
        want = {n: first.slot(n) for n in ("manifold", "rover", "atlas")}
        again = Slots(5, self.p)
        for n, k in want.items():
            self.assertEqual(again.slot(n), k)

    def test_A_NEW_HOST_DOES_NOT_RESHUFFLE_THE_OLD_ONES(self):
        """The reason stickiness is not merely a cache. An assignment computed
        from the live set would move every time the set moved: latch a third
        box and the second one silently changes colour, which is exactly the
        behaviour that makes you stop trusting the hint."""
        s = Slots(5, self.p)
        before = {n: s.slot(n) for n in ("manifold", "rover")}
        for extra in ("atlas", "nimbus", "helios", "charon-box"):
            s.slot(extra)
            for n, k in before.items():
                self.assertEqual(s.slot(n), k,
                                 f"{n} moved when {extra} arrived")

    def test_a_host_that_LEAVES_keeps_its_slot(self):
        """Detaching for an afternoon must not cost the colour you learned.
        Nothing prunes on a detach, on purpose."""
        s = Slots(5, self.p)
        k = s.slot("rover")
        Slots(5, self.p)          # a later daemon, rover not latched
        self.assertEqual(Slots(5, self.p).slot("rover"), k)

    def test_forget_prunes_only_what_it_is_told_to(self):
        s = Slots(5, self.p)
        keep, drop = s.slot("manifold"), s.slot("rover")
        s.forget({"manifold"})
        self.assertEqual(Slots(5, self.p).table, {"manifold": keep})
        self.assertNotEqual(drop, None)

    def test_a_name_with_a_SPACE_reads_back_whole(self):
        """The slot is written first and the name last, the same field order
        and the same reason as mux's per-pane agent record: a free-form field
        that is not last collapses into the whitespace run beside it."""
        s = Slots(5, self.p)
        k = s.slot("a host with spaces")
        self.assertEqual(Slots(5, self.p).table.get("a host with spaces"), k)

    def test_a_CORRUPT_LINE_is_skipped_not_fatal(self):
        """One unreadable record costs one host a fresh slot. Refusing to
        start over a damaged cosmetic file would be the worse failure."""
        with open(self.p, "w", encoding="utf-8") as fh:
            fh.write("2 rover\nnonsense\n\nxx manifold\n4 atlas\n")
        t = Slots(5, self.p).table
        self.assertEqual(t, {"rover": 2, "atlas": 4})

    def test_an_UNWRITABLE_store_never_raises(self):
        """Best effort: a failed write costs stickiness across restarts and
        nothing else, so it must not reach the poll loop that called it."""
        s = Slots(5, os.path.join(self.d, "nope", "deep", "slots"))
        os.chmod(self.d, 0o500)
        try:
            self.assertIn(s.slot("manifold"), range(5))
        finally:
            os.chmod(self.d, 0o700)


class TestLocation(unittest.TestCase):
    def test_it_lives_in_STATE_not_cache(self):
        """It cannot be rebuilt: the order that produced it is gone. That is
        the same test mux-paths.sh applies to the session set, and getting it
        wrong is one `rm -rf ~/.cache` from losing every assignment."""
        os.environ["XDG_STATE_HOME"] = "/x/state"
        try:
            self.assertEqual(state_dir(), "/x/state/mux")
            self.assertTrue(store_path().startswith("/x/state/mux/"))
        finally:
            del os.environ["XDG_STATE_HOME"]

    def test_it_falls_back_to_the_XDG_DEFAULT(self):
        os.environ.pop("XDG_STATE_HOME", None)
        self.assertTrue(state_dir().endswith("/.local/state/mux"))


if __name__ == "__main__":
    unittest.main()
