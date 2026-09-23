"""The source list: WHICH hosts the tray speaks for, and how it is told.

Sources are COMMANDS, not hosts -- the same seam shape as `context-command`
and `MUX_NOTIFY_SEND` -- so `manifestor ssh manifestor mux agent-summary`
works, and so does a jump host, `kubectl exec`, or anything else. The
indicator never learns what ssh is.

These tests pin the parsing and, above all, the FALLBACKS: a tray daemon that
refuses to start, or starts with no items, is indistinguishable from a crashed
one when all you can see is a bar.
"""
import os
import tempfile
import unittest

from mux_indicator.sources import load, local_label, parse


class Parse(unittest.TestCase):
    def test_label_then_command(self):
        got = parse("manifold mux agent-summary\n")
        self.assertEqual(got, [("manifold", ["mux", "agent-summary"])])

    def test_several_sources_keep_their_order(self):
        """Order is the tray's left-to-right order, so it is the user's to set
        and must not be sorted or de-duplicated behind their back."""
        got = parse("b mux agent-summary\na ssh a mux agent-summary\n")
        self.assertEqual([l for l, _ in got], ["b", "a"])

    def test_a_remote_source_is_just_a_longer_command(self):
        got = parse("manifestor ssh manifestor mux agent-summary\n")
        self.assertEqual(
            got, [("manifestor", ["ssh", "manifestor", "mux",
                                  "agent-summary"])])

    def test_quotes_hold_a_command_together(self):
        """shlex, so a source can pass a remote shell one argument. Without it
        `sh -lc 'mux agent-summary'` would split into three broken tokens."""
        got = parse("""h ssh h sh -lc 'mux agent-summary'\n""")
        self.assertEqual(got, [("h", ["ssh", "h", "sh", "-lc",
                                      "mux agent-summary"])])

    def test_comments_follow_mux_conf_clean(self):
        """Full-line and ` #` inline comments go; a # INSIDE a token stays.
        Deliberately identical to mux_conf_clean, so knowing one config file
        means knowing this one."""
        got = parse("# a heading\n"
                    "  # indented\n"
                    "a mux agent-summary  # trailing note\n"
                    "\n"
                    "b cmd --tag=v#1\n")
        self.assertEqual(got, [("a", ["mux", "agent-summary"]),
                               ("b", ["cmd", "--tag=v#1"])])

    def test_a_bad_line_is_dropped_not_raised(self):
        """A typo in one of five hosts must not cost you the other four.
        This file is read by a tray daemon at startup; refusing to start is
        the worst available response to a malformed line."""
        got = parse("good mux agent-summary\n"
                    "lonely-label-with-no-command\n"
                    "unbalanced 'quote mux agent-summary\n"
                    "alsogood mux agent-summary\n")
        self.assertEqual([l for l, _ in got], ["good", "alsogood"])


class Load(unittest.TestCase):
    """The resolution order, and the two fallbacks that matter."""

    def _with(self, content=None, **env):
        """load() against a temp file (or none), with a patched env."""
        old = {k: os.environ.get(k) for k in
               ("MUX_INDICATOR_SOURCES", "MUX_DIR", "XDG_CONFIG_HOME")}
        path = None
        if content is not None:
            fd, path = tempfile.mkstemp(prefix="muxsrc")
            with os.fdopen(fd, "w") as fh:
                fh.write(content)
            self.addCleanup(os.unlink, path)
            env.setdefault("MUX_INDICATOR_SOURCES", path)
        try:
            for k in old:
                os.environ.pop(k, None)
            os.environ.update({k: v for k, v in env.items() if v is not None})
            return load(mux_bin="mux")
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_env_path_is_read(self):
        got = self._with("alpha ssh alpha mux agent-summary\n")
        self.assertEqual(got, [("alpha", ["ssh", "alpha", "mux",
                                          "agent-summary"])])

    def test_no_file_gives_one_local_source(self):
        """The DEFAULT is this machine, which is what the indicator did before
        it could do more -- so an existing install gains a name and loses
        nothing. No config required to keep working."""
        got = self._with(MUX_INDICATOR_SOURCES="/nonexistent/mux-sources")
        self.assertEqual(got, [(local_label(), ["mux", "agent-summary"])])

    def test_an_EMPTY_file_falls_back_too(self):
        """Not just a missing one. A file listing nothing usable would otherwise
        start a daemon with zero items, which from the bar looks exactly like a
        daemon that died -- the failure mode with no feedback at all."""
        got = self._with("# only comments\n\n")
        self.assertEqual(got, [(local_label(), ["mux", "agent-summary"])])

    def test_mux_dir_is_consulted_when_the_env_is_unset(self):
        import pathlib
        d = tempfile.mkdtemp(prefix="muxdir")
        pathlib.Path(d, "indicator-sources").write_text("z mux agent-summary\n")
        got = self._with(MUX_DIR=d)
        self.assertEqual(got, [("z", ["mux", "agent-summary"])])

    def test_local_label_is_a_short_hostname(self):
        """It keys `mux host-color`, so it has to be the same token the status
        bar hashes -- a FQDN would colour the tray differently from the chip."""
        self.assertNotIn(".", local_label())
        self.assertTrue(local_label())


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
