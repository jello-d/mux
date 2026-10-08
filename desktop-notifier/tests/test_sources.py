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
  the tray: the "confidently reporting a host you cannot see" failure the
  whole cross-machine design exists to avoid.

  THE REMOTE COMMAND MUST SURVIVE SSH. Both halves of it were real failures
  first, and both fail by doing something PLAUSIBLE rather than erroring.
"""
import os
import tempfile
import unittest

from mux_desktop_notifier import sources
from mux_desktop_notifier.sources import (DEFAULT_TRANSPORT, latched, load,
                                   local_label, remote_argv, transport)


class Latched(unittest.TestCase):
    """Reading the lock directory."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="muxlatch")

    def _lock(self, name, pid, target):
        with open(os.path.join(self.d, name + ".lock"), "w") as fh:
            fh.write(f"{pid}\n{target}\n")

    def test_a_live_lock_is_a_host(self):
        self._lock("northgate", os.getpid(), "northgate")
        self.assertEqual(latched(self.d), [("northgate", "northgate")])

    def test_the_ADDRESS_not_the_filename_gives_the_host(self):
        """The filename is sanitised through `tr -c`, so `northwood:2222` lands
        as `northwood_2222` and is indistinguishable from a host genuinely
        called that. Polling `northwood_2222` would draw `unknown` forever with
        nothing on screen to say why, so latch writes the address verbatim on
        line 2 and this reads it."""
        self._lock("northwood_2222", os.getpid(), "northwood:2222")
        self.assertEqual(latched(self.d), [("northwood", "northwood:2222")])

    def test_the_PORT_is_split_off_and_kept(self):
        """Line 2 is purely the ADDRESS since 0.84: the partition and session
        moved out of it, so a colon here can only be a port. The host keys the
        item and the port has to reach the transport, which is the gap this
        closed: it was split off to key the item and nothing put it back, so a
        latch to `box:2222` was WATCHED AT 22."""
        self._lock("box_2222", os.getpid(), "box:2222")
        host, addr = latched(self.d)[0]
        self.assertEqual(host, "box")
        self.assertEqual(sources.split_address(addr), ("box", "2222"))

    def test_an_IPv6_LITERAL_is_never_split(self):
        """A colon is a port only when it cannot be anything else, which is
        the rule latch applies to this same field. Guessing wrong here dials a
        host that does not exist while looking like it worked."""
        self.assertEqual(sources.split_address("fe80::1"), ("fe80::1", None))
        self.assertEqual(sources.split_address("[::1]:2222"), ("::1", "2222"))
        self.assertEqual(sources.split_address("box"), ("box", None))

    def test_a_PRE_0_84_target_is_not_dismembered(self):
        """`box:a:b` was a legal lock line when line 2 still carried the
        partition and session. It is not an address, so it is NOT split into a
        host called `box`: three tests used to assert exactly that and passed
        by coincidence, because the old first-colon split gives the same
        answer for an address with a port. Treating a two-colon value as
        `HOST:PORT` is the IPv6 trap pointed the other way."""
        self.assertEqual(sources.split_address("box:a:b"), ("box:a:b", None))

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
        """`mux agent status --all` answers for the whole box, so two items
        for one host would be identical twins: a puzzle rather than
        information. Two latches to the same host differ by PARTITION now,
        which the lock no longer carries, so both write the same address."""
        self._lock("box_api", os.getpid(), "box")
        self._lock("box_web", os.getpid(), "box")
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
        self.assertEqual(got,
                         [(local_label(),
                           ["mux", "agent", "status", "--all"])])

    def test_local_comes_first(self):
        """So the left-hand item does not move as latches come and go."""
        self._lock("zzz", "zzz")
        self.assertEqual(load(self.d)[0][0], local_label())

    def test_a_latched_host_is_added(self):
        self._lock("northgate", "northgate")
        self.assertIn("northgate", [l for l, _ in load(self.d)])

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
    failed by doing something PLAUSIBLE instead of erroring, which is the kind
    that survives a green suite.
    """

    def test_the_command_is_ONE_argv_element(self):
        """ssh CONCATENATES its remaining arguments and the remote shell
        re-splits them. Passed as separate words, the far side ran `sh -lc mux`
        with `agent-summary` as $0 (mux's bare session PICKER), which
        answered a menu that parsed as the state `1)`."""
        argv = remote_argv("box", "ssh %h %q")
        self.assertEqual(argv[0], "ssh")
        self.assertEqual(argv[1], "box")
        self.assertEqual(len(argv), 3)
        self.assertIn("agent status", argv[2])

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
        old = os.environ.get("MUX_DESKTOP_NOTIFIER_TRANSPORT")
        os.environ["MUX_DESKTOP_NOTIFIER_TRANSPORT"] = "kubectl exec %h -- %q"
        try:
            self.assertEqual(remote_argv("pod")[0], "kubectl")
        finally:
            if old is None:
                os.environ.pop("MUX_DESKTOP_NOTIFIER_TRANSPORT", None)
            else:
                os.environ["MUX_DESKTOP_NOTIFIER_TRANSPORT"] = old

    def test_the_default_is_used_when_nothing_is_configured(self):
        old = os.environ.get("MUX_DESKTOP_NOTIFIER_TRANSPORT")
        old_dir = os.environ.get("MUX_DIR")
        os.environ.pop("MUX_DESKTOP_NOTIFIER_TRANSPORT", None)
        os.environ["MUX_DIR"] = tempfile.mkdtemp(prefix="muxconf")
        try:
            self.assertEqual(transport(), DEFAULT_TRANSPORT)
        finally:
            for k, v in (("MUX_DESKTOP_NOTIFIER_TRANSPORT", old),
                         ("MUX_DIR", old_dir)):
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class TransportFromConfig(unittest.TestCase):
    """`desktop-notifier-transport` in $MUX_DIR/config: the MIDDLE layer of the
    three, and the only one that had never been read.

    The env override and the shipped default were both covered; a 2026-09-26
    coverage sweep showed the `return` inside the config parser had never once
    executed, so the documented config key worked only by assumption. Same
    shape as the two shipped latch hooks that turned out to be completely dark.
    """

    def _conf(self, text):
        d = tempfile.mkdtemp(prefix="muxconf")
        with open(os.path.join(d, "config"), "w") as fh:
            fh.write(text)
        old_dir = os.environ.get("MUX_DIR")
        old_env = os.environ.get("MUX_DESKTOP_NOTIFIER_TRANSPORT")
        os.environ["MUX_DIR"] = d
        os.environ.pop("MUX_DESKTOP_NOTIFIER_TRANSPORT", None)

        def restore():
            for k, v in (("MUX_DIR", old_dir),
                         ("MUX_DESKTOP_NOTIFIER_TRANSPORT", old_env)):
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        return d

    def test_the_config_key_is_READ(self):
        # conventions: allow -- every `--` in this class sits inside a kubectl
        # command TEMPLATE, where it is kubectl's own end-of-options separator
        # between the pod and the remote argv. It is syntax under test, not
        # punctuation, so rewording it would change what is being asserted.
        self._conf("desktop-notifier-transport kubectl exec %h -- %q\n")
        self.assertEqual(transport(), "kubectl exec %h -- %q")

    def test_it_reaches_the_argv(self):
        """Separate from reading it: a value parsed and then dropped on the
        floor looks identical from the config's side."""
        # conventions: allow -- kubectl's separator, as above.
        self._conf("desktop-notifier-transport kubectl exec %h -- %q\n")
        self.assertEqual(remote_argv("pod")[:3], ["kubectl", "exec", "pod"])

    def test_ENV_STILL_BEATS_THE_CONFIG(self):
        """The precedence the whole seam claims: environment, then config,
        then shipped. With the config now actually being read, this is the
        first test that can fail for the right reason."""
        self._conf("desktop-notifier-transport from-the-config %h %q\n")
        os.environ["MUX_DESKTOP_NOTIFIER_TRANSPORT"] = "from-the-env %h %q"
        self.assertEqual(transport(), "from-the-env %h %q")

    def test_a_COMMENTED_OUT_key_is_not_read(self):
        """`# desktop-notifier-transport ...` is how somebody disables it.
        Reading it
        anyway would silently ignore the disabling."""
        # conventions: allow -- kubectl's separator, as above.
        self._conf("  # desktop-notifier-transport kubectl exec %h -- %q\n")
        self.assertEqual(transport(), DEFAULT_TRANSPORT)

    def test_an_INLINE_comment_is_stripped(self):
        self._conf("desktop-notifier-transport ssh %h %q   # the usual\n")
        self.assertEqual(transport(), "ssh %h %q")

    def test_OTHER_directives_are_ignored(self):
        """mux's config holds every seam, so the file this reads is full of
        keys that are none of its business."""
        self._conf("context-command severance current\n"
                   "latch-transport ssh -t %h sh -lc %q\n"
                   "\n"
                   "desktop-notifier-transport mine %h %q\n")
        self.assertEqual(transport(), "mine %h %q")

    def test_a_key_with_NO_VALUE_is_ignored(self):
        """A bare key is not a template. Returning an empty one would make
        remote_argv produce an empty argv and every host go unknown."""
        self._conf("desktop-notifier-transport\n")
        self.assertEqual(transport(), DEFAULT_TRANSPORT)

    def test_an_UNREADABLE_config_falls_back(self):
        """A directory where the file should be: the tray must still come up
        on the default rather than refusing to start."""
        d = self._conf("desktop-notifier-transport nope %h %q\n")
        os.remove(os.path.join(d, "config"))
        os.mkdir(os.path.join(d, "config"))
        self.assertEqual(transport(), DEFAULT_TRANSPORT)


class LockReading(unittest.TestCase):
    """The error paths in latch-lock discovery, which decide whether a host
    appears in the tray at all."""

    def test_an_unreadable_lock_is_SKIPPED_not_fatal(self):
        """One bad lock must not cost every other host its tray item."""
        d = tempfile.mkdtemp(prefix="muxlock")
        os.mkdir(os.path.join(d, "bad.lock"))          # a dir, not a file
        with open(os.path.join(d, "good.lock"), "w") as fh:
            fh.write("%d\nrover\n" % os.getpid())
        self.assertEqual(latched(d), [("rover", "rover")])

    def test_a_pid_owned_by_SOMEONE_ELSE_counts_as_alive(self):
        """`os.kill(pid, 0)` raises PermissionError for a live process owned by
        another uid. Reading that as dead would drop a host from the tray
        because of who started it: pid 1 is always there and never ours."""
        d = tempfile.mkdtemp(prefix="muxlock")
        with open(os.path.join(d, "init.lock"), "w") as fh:
            fh.write("1\nrover\n")
        self.assertEqual(latched(d), [("rover", "rover")])

    def test_a_NON_NUMERIC_pid_is_skipped(self):
        d = tempfile.mkdtemp(prefix="muxlock")
        with open(os.path.join(d, "junk.lock"), "w") as fh:
            fh.write("not-a-pid\nrover\n")
        self.assertEqual(latched(d), [])

    def test_the_default_run_dir_is_derived_from_XDG(self):
        """The no-argument call is what the daemon actually makes; every other
        test here passes a path and never exercises it."""
        old = os.environ.get("XDG_RUNTIME_DIR")
        d = tempfile.mkdtemp(prefix="muxrun")
        os.mkdir(os.path.join(d, "mux-latch"))
        with open(os.path.join(d, "mux-latch", "r.lock"), "w") as fh:
            fh.write("%d\nrover\n" % os.getpid())
        os.environ["XDG_RUNTIME_DIR"] = d
        try:
            self.assertEqual(latched(), [("rover", "rover")])
        finally:
            if old is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = old


class Label(unittest.TestCase):
    def test_local_label_is_a_short_hostname(self):
        """It keys `mux host-color`, so it has to be the token the status bar
        hashes: a FQDN would colour the tray differently from the chip."""
        self.assertNotIn(".", local_label())
        self.assertTrue(local_label())


if __name__ == "__main__":                              # pragma: no cover
    unittest.main()


class ActivateSeam(unittest.TestCase):
    """The focus hook: mux says WHAT, the integrator says HOW.

    Clicking a tray item switches that host's session, which mux owns. Raising
    the terminal that shows it means knowing about a compositor, which mux
    does not get to know about: the same boundary that put window placement
    in usher. So it is a seam, unset by default, and a click still does the
    half mux legitimately owns when nobody wired one.
    """

    def _conf(self, text):
        d = tempfile.mkdtemp(prefix="muxact")
        with open(os.path.join(d, "config"), "w") as fh:
            fh.write(text)
        old_dir = os.environ.get("MUX_DIR")
        old_env = os.environ.get("MUX_DESKTOP_NOTIFIER_ACTIVATE")
        os.environ["MUX_DIR"] = d
        os.environ.pop("MUX_DESKTOP_NOTIFIER_ACTIVATE", None)

        def restore():
            for k, v in (("MUX_DIR", old_dir),
                         ("MUX_DESKTOP_NOTIFIER_ACTIVATE", old_env)):
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        return d

    def test_UNSET_IS_THE_DEFAULT(self):
        """The third answer, not a missing one: nobody asked for a focus
        change, so none happens. A default here would make mux reach into a
        compositor on every install."""
        self._conf("context-command severance current\n")
        self.assertIsNone(sources.activate_hook())

    def test_the_config_key_is_read(self):
        self._conf("desktop-notifier-activate focus-kitty\n")
        self.assertEqual(sources.activate_hook(), "focus-kitty")

    def test_env_beats_config(self):
        self._conf("desktop-notifier-activate from-the-config\n")
        os.environ["MUX_DESKTOP_NOTIFIER_ACTIVATE"] = "from-the-env"
        self.assertEqual(sources.activate_hook(), "from-the-env")

    def test_a_hook_with_ARGUMENTS_survives(self):
        """It is a command LINE, not a program name: `focus-window --title`
        has to reach the hook as two words."""
        self._conf("desktop-notifier-activate focus-window --raise\n")
        self.assertEqual(sources.activate_hook(), "focus-window --raise")


class ActivateCommand(unittest.TestCase):
    def test_the_remote_click_asks_for_next_blocked(self):
        """Not agent-summary. The same transport carries both, so the COMMAND
        is what distinguishes a poll from a click: passing the wrong one
        would make every click silently re-read the state it already had."""
        argv = sources.remote_argv("box", template="ssh %h %q",
                                   cmd=sources.activate_cmd())
        self.assertIn("mux next-blocked", " ".join(argv))
        self.assertNotIn("agent-summary", " ".join(argv))

    def test_the_PARTITION_travels_with_the_click(self):
        """Without it every item on a host does the same thing: the far side's
        login shell resolves its own default and jumps there, landing on a
        real session that is not the one clicked. Plausible, and silent."""
        argv = sources.remote_argv("box", template="ssh %h %q",
                                   cmd=sources.activate_cmd("work"))
        self.assertIn("mux next-blocked --partition work", " ".join(argv))

    def test_a_partition_that_is_not_a_LABEL_is_refused(self):
        """These names arrive from another machine and go straight back out
        inside `sh -lc`, so this is untrusted input crossing into a shell. The
        click still happens: it simply asks for the host's own default,
        which is what an item with no partition asks for anyway."""
        for bad in ("a b", "a;rm -rf /", "a'b", "../x", "A", ""):
            got = sources.activate_cmd(bad)
            self.assertEqual(got, sources.activate_cmd(),
                             f"{bad!r} reached the remote command line")

    def test_the_poll_asks_for_EVERY_partition(self):
        """One round trip per host, not one per partition. That is the whole
        reason `--all` exists: a reader on another box cannot know the names
        to ask for, and over a transport N partitions must not mean N ssh
        connections."""
        argv = sources.remote_argv("box", template="ssh %h %q")
        self.assertIn("mux agent status", " ".join(argv))

    def test_the_poll_reads_the_MACHINE_contract(self):
        """The tray is a program, so it reads the surface that promises a
        stable shape. That is the whole point of the namespace: polling the
        human-facing summary meant improving it for a terminal could silently
        break this, and nothing declared which was which.

        The attached-only property moved WITH the verb: it is the default of
        `mux agent status` now, asserted in test/mux-agent.t rather than here,
        because it became the contract's promise instead of this caller's
        flag."""
        argv = sources.remote_argv("box", template="ssh %h %q")
        self.assertIn("mux agent status", " ".join(argv))
        self.assertNotIn("agent-summary", " ".join(argv))

    def test_every_partition_is_asked_for_EXPLICITLY(self):
        """`--all` was parsed and never read until 0.73, so this daemon got
        every partition by accident and depended on it. Once the verb honours
        its own documented scoping, omitting the flag reduces a remote host to
        whichever partition its login shell resolves, which is exactly the
        blindness 0.56 existed to fix, and it would come back silently: the
        tray would simply stop publishing an item, which reads as "that
        partition is gone".

        Asserted for BOTH forms, because they are built by different code and
        a local host has partitions too."""
        argv = sources.remote_argv("box", template="ssh %h %q")
        self.assertIn("--all", " ".join(argv))
        self.assertIn("--all", list(sources.LOCAL_CMD))

    def test_the_poll_is_not_the_CLICK(self):
        """The other direction, asserted separately: a default that leaked the
        activate command would break the feed itself."""
        argv = sources.remote_argv("box", template="ssh %h %q")
        self.assertNotIn("next-blocked", " ".join(argv))


class Streams(unittest.TestCase):
    """Which sources can be read as a long-lived stream, and how.

    THE REMOTE HALF IS WHAT THE DESIGN WAS FOR. Polling opened a connection to
    every latched host every few seconds; a stream moves the polling on to the
    watched box, so only CHANGES cross the network and a transition is visible
    when it happens rather than up to a poll later. That is also the only way
    a remote agent's banner can ever reach the desk the human is sitting at.
    """

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="muxlatch")

    def _lock(self, name, target):
        with open(os.path.join(self.d, name + ".lock"), "w") as fh:
            fh.write(f"{os.getpid()}\n{target}\n")

    def test_the_local_source_streams(self):
        got = sources.streams(self.d)
        self.assertEqual(got, [(local_label(),
                                ["mux", "agent", "stream", "--all"])])

    def test_a_latched_host_streams_too(self):
        self._lock("northgate", "northgate")
        got = dict(sources.streams(self.d))
        self.assertIn("northgate", got)

    def test_the_remote_stream_asks_for_the_STREAM(self):
        """Not the one-shot query. Both exist and differ by one word, so the
        failure of getting this wrong is a feed that answers once, exits, and
        is respawned for ever: a poll wearing a stream's costs."""
        self._lock("box", "box")
        argv = dict(sources.streams(self.d))["box"]
        self.assertTrue(any("agent stream" in w for w in argv),
                        f"no stream verb in {argv}")
        self.assertFalse(any("agent status" in w for w in argv),
                         f"the one-shot query leaked into the stream: {argv}")

    def test_the_remote_command_is_ONE_argv_element(self):
        """ssh concatenates its remaining arguments and the remote shell
        re-splits them, so a command spread over several elements arrives as
        `sh -lc mux` with the rest as $0 and runs the bare session PICKER.
        mux has shipped that bug twice; here it would read the picker's output
        as a state and draw a calm tile for a feed that never worked."""
        self._lock("box", "box")
        argv = dict(sources.streams(self.d))["box"]
        whole = [w for w in argv if "agent stream" in w]
        self.assertEqual(len(whole), 1, f"split across elements: {argv}")
        self.assertIn("sh -lc", whole[0],
                      "sshd runs a remote command with no login shell, so "
                      "mux is not on PATH without one")

    def test_the_two_enumerations_AGREE(self):
        """One host set, asked two ways. If they ever disagree a host gets a
        poll and a stream at once, or neither, and the tray's own rule is that
        the answer which repaints the items is also the one that decides which
        items exist."""
        self._lock("alpha", "alpha")
        self._lock("beta", "beta:2222")
        self.assertEqual([l for l, _ in load(self.d)],
                         [l for l, _ in sources.streams(self.d)])

    def test_a_latch_to_OURSELVES_does_not_stream_twice(self):
        self._lock("self", local_label())
        self.assertEqual(len(sources.streams(self.d)), 1)


class Port(unittest.TestCase):
    """The port reaches the transport, which it did not until now.

    THE LOCK'S ADDRESS CARRIES `HOST[:PORT]` and the tray split the port off
    to key its item by host, then built the argv from the host alone. So a
    latch to `box:2222` was polled at 22: an item reading `unknown` for ever
    about a box that is perfectly reachable, or worse, whatever answers on 22.
    Nothing regressed when ports arrived in 0.84 because there were none
    before, which is exactly why it went unnoticed.
    """

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="muxlatch")

    def _lock(self, name, addr):
        with open(os.path.join(self.d, name + ".lock"), "w") as fh:
            fh.write(f"{os.getpid()}\n{addr}\n")

    def test_the_default_comes_from_the_TEMPLATE(self):
        """`-p %p:22` reads as "the port, or 22". The default cannot live in
        mux: 22 being ssh's and 2022 being ET's is knowledge of a transport,
        and the whole seam exists so mux does not have any."""
        argv = sources.remote_argv("box", sources.DEFAULT_TRANSPORT)
        self.assertIn("22", argv)
        self.assertEqual(argv[argv.index("-p") + 1], "22")

    def test_an_explicit_port_WINS(self):
        argv = sources.remote_argv("box", sources.DEFAULT_TRANSPORT,
                                   port="2222")
        self.assertEqual(argv[argv.index("-p") + 1], "2222")

    def test_the_longer_token_is_substituted_FIRST(self):
        """`%p:22` CONTAINS `%p`, so substituting the bare one first leaves
        `:22` behind and asks ssh for port `22222`. Ordering, not cleverness,
        and the kind of thing that works on every machine with no port set."""
        argv = sources.remote_argv("box", "ssh -p %p:22 %h %q", port="2222")
        self.assertEqual(argv[argv.index("-p") + 1], "2222")

    def test_a_template_with_NO_port_token_still_works(self):
        """Every transport line written before ports existed. A template that
        never mentions `%p` must never see one."""
        argv = sources.remote_argv("box", "ssh %h %q", port="2222")
        self.assertNotIn("2222", argv)
        self.assertIn("box", argv)

    def test_a_bare_token_with_no_port_goes_EMPTY_not_away(self):
        """What latch does with the same token, and one grammar is the whole
        argument for mirroring it. Dropping the WORD was the first version and
        is the worse failure: `-p` and `%p` are separate shell words, so
        dropping one leaves its flag to swallow the next argument, and
        `ssh -p box` dials nothing while looking like a dial."""
        argv = sources.remote_argv("box", "ssh -p %p %h %q")
        self.assertEqual(argv[argv.index("-p") + 1], "")
        self.assertIn("box", argv)

    def test_the_PORT_REACHES_both_the_poll_and_the_stream(self):
        """The load-bearing one: everything above tests the substitution, and
        this tests that a caller actually passes it. The enumeration splits
        the address to key the item, so the port is one `[1]` away from being
        dropped again, and in BOTH functions."""
        self._lock("box_2222", "box:2222")
        got = dict(sources.load(self.d))
        self.assertIn("2222", got["box"], f"the poll lost the port: {got}")
        got = dict(sources.streams(self.d))
        self.assertIn("2222", got["box"], f"the stream lost the port: {got}")


class HookResolution(unittest.TestCase):
    """Turning a hook NAME into something exec can find.

    IT WAS MISSING, AND THE SAMPLES WERE THEREFORE UNREACHABLE. config.sample
    documents `desktop-notifier-activate focus-kitty`; that bare name is NOT
    on PATH and installs under `$MUX_SHARE/desktop-notifier/`, so the one
    spelling the documentation teaches could not resolve and the click
    reported "failed to start" about a file the user can see on disk. latch
    has had this resolver since 0.31; the notifier never did.

    THE SAME THREE CASES AS latch's `_hook`, so a reader who knows one knows
    the other: a `/` makes it a literal path, `none` disables the seam, and a
    bare name is resolved overlay-first.
    """

    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        self.root = self._t.name
        self._env = {}
        for k in ("MUX_DIR", "MUX_SHARE"):
            self._env[k] = os.environ.get(k)
        self.addCleanup(self._restore)

    def _restore(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _hook(self, base, name="toast-x"):
        d = os.path.join(self.root, base, "desktop-notifier")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)
        return p

    def test_a_bare_name_resolves_against_the_SHIPPED_tree(self):
        want = self._hook("share")
        os.environ["MUX_DIR"] = os.path.join(self.root, "conf")
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        self.assertEqual(sources.hook_path("toast-x"), want)

    def test_the_USER_OVERLAY_wins(self):
        """$MUX_DIR before $MUX_SHARE, the same order layouts, themes and
        latch's hooks already use: a shipped sample is a starting point and
        the user's copy of it has to be reachable by the same name."""
        self._hook("share")
        mine = self._hook("conf")
        os.environ["MUX_DIR"] = os.path.join(self.root, "conf")
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        self.assertEqual(sources.hook_path("toast-x"), mine)

    def test_ARGUMENTS_survive_the_resolution(self):
        """Only the leading WORD is a path. A hook carrying flags is a
        command line in config, and resolving the whole string would look
        for a file whose name contains a space."""
        want = self._hook("share")
        os.environ["MUX_DIR"] = os.path.join(self.root, "conf")
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        self.assertEqual(sources.hook_path("toast-x --dim #333"),
                         want + " --dim #333")

    def test_a_PATH_is_taken_literally(self):
        """Anything with a `/` is the caller being explicit, and searching
        for it would silently prefer a same-named sample."""
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        self._hook("share", name="toast-x")
        self.assertEqual(sources.hook_path("/usr/local/bin/toast-x"),
                         "/usr/local/bin/toast-x")

    def test_none_DISABLES_the_seam(self):
        """The one spelling for "I do not want one", the same word
        `mux capabilities` uses for a declared absence and latch for a seam
        turned off. Without it an empty value reads as UNSET and falls back
        to the default instead."""
        self.assertIsNone(sources.hook_path("none"))

    def test_an_UNRESOLVABLE_name_is_left_for_PATH(self):
        """Not an error here: the value may name something on PATH, and
        refusing it would break a hook that is simply installed elsewhere.
        Failing to exec is reported by the caller, with the name in it."""
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        os.makedirs(os.path.join(self.root, "share", "desktop-notifier"),
                    exist_ok=True)
        self.assertEqual(sources.hook_path("nosuchhook"), "nosuchhook")

    def test_a_NON_EXECUTABLE_file_is_not_resolved(self):
        """Present and unrunnable is not a hook. Resolving it would turn a
        forgotten chmod into "failed to start" naming a path that exists,
        which reads as mux being wrong about its own tree."""
        d = os.path.join(self.root, "share", "desktop-notifier")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "toast-x")
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(p, 0o644)
        os.environ["MUX_SHARE"] = os.path.join(self.root, "share")
        self.assertEqual(sources.hook_path("toast-x"), "toast-x")
