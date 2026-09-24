"""WHICH hosts the tray speaks for, discovered from `mux latch`'s own locks.

There is no config file. `mux latch` already writes
$XDG_RUNTIME_DIR/mux-latch/<target>.lock at start and removes it via a trap on
every exit path, so the directory IS a live registry of what this box is
attached to. The tray follows it: latch to a box and its item appears, detach
and it goes, with nothing to edit on any machine.

That makes the LOCK FORMAT A CONTRACT between two programs, which is what most
of this file pins. The rest pins the two failure directions that would be
invisible from the bar:

  A STALE LOCK IS NOT A HOST. The pid on line 1 is what makes a killed latch
  detectable. Poll a dead one and a crashed latch leaves a permanent phantom in
  the tray -- the "confidently reporting a host you cannot see" failure the
  whole cross-machine design exists to avoid.

  THE REMOTE COMMAND MUST SURVIVE SSH. Both halves of it were real failures
  first, and both fail by doing something PLAUSIBLE rather than erroring.
"""
import os
import tempfile
import unittest

from mux_indicator.sources import (DEFAULT_TRANSPORT, latched, load,
                                   local_label, remote_argv, transport)


class Latched(unittest.TestCase):
    """Reading the lock directory."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="muxlatch")

    def _lock(self, name, pid, target):
        with open(os.path.join(self.d, name + ".lock"), "w") as fh:
            fh.write(f"{pid}\n{target}\n")

    def test_a_live_lock_is_a_host(self):
        self._lock("manifestor", os.getpid(), "manifestor")
        self.assertEqual(latched(self.d), [("manifestor", "manifestor")])

    def test_the_TARGET_not_the_filename_gives_the_host(self):
        """The filename is sanitised through `tr -c`, so `manifold:api` lands as
        `manifold_api` and is indistinguishable from a host genuinely called
        that. Polling `manifold_api` would draw `unknown` forever with nothing
        on screen to say why -- so latch writes the target verbatim on line 2
        and this reads it."""
        self._lock("manifold_api", os.getpid(), "manifold:api")
        self.assertEqual(latched(self.d), [("manifold", "manifold:api")])

    def test_a_session_name_may_contain_a_colon(self):
        """The target grammar: the host is everything before the FIRST colon."""
        self._lock("box_a_b", os.getpid(), "box:a:b")
        self.assertEqual(latched(self.d)[0][0], "box")

    def test_A_STALE_LOCK_IS_SKIPPED(self):
        """A crashed latch must not leave a permanent phantom host in the tray.
        pid 2**31-1 is chosen to be unallocatable rather than merely unused."""
        self._lock("ghost", 2 ** 31 - 1, "ghost")
        self.assertEqual(latched(self.d), [])

    def test_a_lock_with_no_target_is_skipped(self):
        """A one-line lock predates the format. Guessing the host from the
        filename is exactly the ambiguity line 2 exists to remove, so an old
        lock is ignored rather than half-read."""
        with open(os.path.join(self.d, "old.lock"), "w") as fh:
            fh.write(f"{os.getpid()}\n")
        self.assertEqual(latched(self.d), [])

    def test_a_garbage_lock_does_not_raise(self):
        """The daemon outlives a junk file in the runtime directory."""
        with open(os.path.join(self.d, "junk.lock"), "w") as fh:
            fh.write("not-a-pid\nhost\n")
        self.assertEqual(latched(self.d), [])

    def test_non_lock_files_are_ignored(self):
        with open(os.path.join(self.d, "README"), "w") as fh:
            fh.write(f"{os.getpid()}\nhost\n")
        self.assertEqual(latched(self.d), [])

    def test_a_missing_directory_is_not_an_error(self):
        """No latch has ever run on this box. That is the common case."""
        self.assertEqual(latched("/nonexistent/mux-latch"), [])

    def test_two_latches_to_one_host_are_ONE_item(self):
        """`mux agent-summary` answers for the whole box, so two items for
        `box:api` and `box:web` would be identical twins -- a puzzle rather
        than information."""
        self._lock("box_api", os.getpid(), "box:api")
        self._lock("box_web", os.getpid(), "box:web")
        self.assertEqual([h for h, _ in latched(self.d)], ["box"])


class Load(unittest.TestCase):
    """The full published set: this machine, plus whoever it is latched to."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="muxlatch")

    def _lock(self, name, target):
        with open(os.path.join(self.d, name + ".lock"), "w") as fh:
            fh.write(f"{os.getpid()}\n{target}\n")

    def test_the_local_host_is_always_there(self):
        """It is the daemon's own box, not a "which hosts" choice, and showing
        it is what the indicator did before it could do anything else. A tray
        that went empty when you detached would be a regression."""
        got = load(self.d)
        self.assertEqual(got, [(local_label(), ["mux", "agent-summary"])])

    def test_local_comes_first(self):
        """So the left-hand item does not move as latches come and go."""
        self._lock("zzz", "zzz")
        self.assertEqual(load(self.d)[0][0], local_label())

    def test_a_latched_host_is_added(self):
        self._lock("manifestor", "manifestor")
        self.assertIn("manifestor", [l for l, _ in load(self.d)])

    def test_a_latch_to_OURSELVES_is_not_a_second_item(self):
        """Latching to your own hostname is legal and would otherwise publish
        the same box twice, once locally and once through ssh."""
        self._lock("self", local_label())
        self.assertEqual(len(load(self.d)), 1)

    def test_the_remote_source_is_not_the_local_command(self):
        """The local item runs `mux agent-summary` directly; a remote one has to
        be carried. If these ever produced the same argv the tray would poll
        THIS box twice and report a remote host's state as our own."""
        self._lock("elsewhere", "elsewhere")
        got = dict(load(self.d))
        self.assertNotEqual(got["elsewhere"], got[local_label()])


class RemoteCommand(unittest.TestCase):
    """Composing the command that asks a remote host for its state.

    Both properties below were live failures before they were tests, and both
    failed by doing something PLAUSIBLE instead of erroring -- which is the kind
    that survives a green suite.
    """

    def test_the_command_is_ONE_argv_element(self):
        """ssh CONCATENATES its remaining arguments and the remote shell
        re-splits them. Passed as separate words, the far side ran `sh -lc mux`
        with `agent-summary` as $0 -- mux's bare session PICKER -- which
        answered a menu that parsed as the state `1)`."""
        argv = remote_argv("box", "ssh %h %q")
        self.assertEqual(argv[0], "ssh")
        self.assertEqual(argv[1], "box")
        self.assertEqual(len(argv), 3)
        self.assertIn("agent-summary", argv[2])

    def test_a_LOGIN_shell_is_used(self):
        """sshd runs a remote command WITHOUT a login shell, so a bare
        `ssh host mux agent-summary` gets PATH with no ~/.local/bin and exits
        127. Measured on this fleet; it is the first thing a real remote
        source hits."""
        self.assertIn("-lc", remote_argv("box", "ssh %h %q")[2])

    def test_the_default_never_prompts(self):
        """A tray daemon cannot answer a password or a host-key question.
        Failing fast is what turns an unreachable host into `unknown` rather
        than a poll wedged forever on a prompt nobody can see."""
        self.assertIn("BatchMode=yes", DEFAULT_TRANSPORT)
        self.assertIn("ConnectTimeout", DEFAULT_TRANSPORT)

    def test_the_host_substitutes_inside_a_word(self):
        """So a template can say `-o HostName=%h` or `user@%h`."""
        self.assertIn("jello@box", remote_argv("box", "ssh jello@%h %q"))

    def test_the_template_is_a_seam(self):
        """ssh is a DEFAULT, not a law: mux specifies the shape of the answer,
        never the mechanism. Same rule `latch-transport` already follows."""
        old = os.environ.get("MUX_INDICATOR_TRANSPORT")
        os.environ["MUX_INDICATOR_TRANSPORT"] = "kubectl exec %h -- %q"
        try:
            self.assertEqual(remote_argv("pod")[0], "kubectl")
        finally:
            if old is None:
                os.environ.pop("MUX_INDICATOR_TRANSPORT", None)
            else:
                os.environ["MUX_INDICATOR_TRANSPORT"] = old

    def test_the_default_is_used_when_nothing_is_configured(self):
        old = os.environ.get("MUX_INDICATOR_TRANSPORT")
        old_dir = os.environ.get("MUX_DIR")
        os.environ.pop("MUX_INDICATOR_TRANSPORT", None)
        os.environ["MUX_DIR"] = tempfile.mkdtemp(prefix="muxconf")
        try:
            self.assertEqual(transport(), DEFAULT_TRANSPORT)
        finally:
            for k, v in (("MUX_INDICATOR_TRANSPORT", old),
                         ("MUX_DIR", old_dir)):
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class Label(unittest.TestCase):
    def test_local_label_is_a_short_hostname(self):
        """It keys `mux host-color`, so it has to be the token the status bar
        hashes -- a FQDN would colour the tray differently from the chip."""
        self.assertNotIn(".", local_label())
        self.assertTrue(local_label())


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()
