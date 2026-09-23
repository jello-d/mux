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


class QueryMux(unittest.TestCase):
    """Running the feed command, and telling "quiet" from "could not ask"."""

    def test_a_missing_binary_is_none_not_a_crash(self):
        """The daemon outlives a broken PATH. It polls forever; one failed
        lookup must not end it, and must not be read as a state either."""
        sni = _fresh(MUX_BIN="/nonexistent/definitely-not-mux")
        self.assertIsNone(asyncio.run(sni._query_mux()))

    def test_output_is_parsed(self):
        sni = _fresh(MUX_BIN=self._stub("working 2\n", 0))
        self.assertEqual(asyncio.run(sni._query_mux()), ("working", 2))

    def test_an_empty_answer_is_still_an_answer(self):
        """`none 0` from a host with no agents is a FACT, and exits 0."""
        sni = _fresh(MUX_BIN=self._stub("none 0\n", 0))
        self.assertEqual(asyncio.run(sni._query_mux()), ("none", None))

    def _stub(self, out, rc):
        """A throwaway executable standing in for `mux`."""
        import stat
        import tempfile
        fd, path = tempfile.mkstemp(prefix="muxstub", suffix=".sh")
        with os.fdopen(fd, "w") as fh:
            fh.write("#!/bin/sh\nprintf '%s'\nexit %d\n" % (out, rc))
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.addCleanup(os.unlink, path)
        return path


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
