"""WHICH hosts the tray speaks for, discovered rather than configured.

THE BOX YOU ARE SITTING AT PULLS; nothing is pushed to it. Every
platform-specific decision then happens on that box, which is the only place it
belongs.

NO CONFIG FILE. The set is `mux latch`'s own lock directory, which is already a
live registry of what this box is attached to: `mux latch` writes
$XDG_RUNTIME_DIR/mux-latch/<target>.lock at start (pid on line 1, the target
verbatim on line 2) and removes it via a trap on every exit path. So a host
appears in the tray when you latch to it and leaves when you detach, with
nothing to stand up, tear down, or keep in sync -- and nothing to edit on each
machine. A second job for a file that already did it perfectly.

THE LOCAL HOST IS ALWAYS PRESENT and is not part of that choice: it is the
daemon's own box, it needs no transport, and showing it is what the indicator
did before it could do anything else.

A STALE LOCK IS NOT A HOST. The pid on line 1 is what makes a killed run
detectable, so a lock whose process is gone is skipped rather than polled --
otherwise a crashed latch would leave a permanent phantom in the tray, which is
exactly the "confidently reporting a host you cannot see" failure the whole
design exists to avoid.

SOURCES ARE STILL COMMANDS. The remote command is composed from a TEMPLATE, the
same seam shape as `latch-transport`, so ssh is a default and not a law: point
`indicator-transport` at anything that carries a command to a host. mux
specifies the shape of the answer, never the mechanism.
"""
import os
import re
import shlex
import socket

# The comment rule is mux_conf_clean's, deliberately: a FULL-LINE comment goes,
# and an INLINE comment is WHITESPACE then #. A hash INSIDE a token survives, so
# a template containing one is safe. Kept identical to mux-conf.sh so a user who
# knows one config file knows this one.
_FULL = re.compile(r"^\s*#")
_INLINE = re.compile(r"\s#.*$")

# %h is the host, %q the remote command as ONE shell-quoted argument.
#
# BOTH HALVES ARE MEASURED, NOT ASSUMED, and each was a real failure first:
#
#   `sh -lc %q` because sshd runs a remote command WITHOUT a login shell, so a
#   bare `ssh host mux agent-summary` gets PATH with no ~/.local/bin and exits
#   127. Verified on this fleet.
#
#   %q rather than passing the words through, because ssh CONCATENATES its
#   remaining arguments and the remote shell re-splits them: unquoted, the far
#   side ran `sh -lc mux` with `agent-summary` as $0, which is mux's bare
#   session PICKER. It answered a menu, which parsed as the state `1)`. That
#   fails by doing something plausible rather than erroring.
#
# BatchMode=yes because a tray daemon can never answer a prompt; failing fast is
# what turns an unreachable host into `unknown` instead of a wedged poll.
DEFAULT_TRANSPORT = (
    "ssh -o BatchMode=yes -o ConnectTimeout=6 "
    "-o StrictHostKeyChecking=accept-new %h %q"
)
REMOTE_CMD = "sh -lc 'mux agent-summary'"


def local_label():
    """This machine's short hostname: the local item's label, and the token
    `mux host-color` hashes -- so a FQDN here would colour the tray differently
    from the status bar."""
    return socket.gethostname().split(".")[0] or "local"


def _mux_dir():
    return os.environ.get("MUX_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME")
        or os.path.join(os.path.expanduser("~"), ".config"), "mux")


def transport():
    """The remote-command template: env, then $MUX_DIR/config, then the default.
    The same environment-over-config-over-shipped order every mux seam uses."""
    env = os.environ.get("MUX_INDICATOR_TRANSPORT")
    if env:
        return env
    try:
        with open(os.path.join(_mux_dir(), "config")) as fh:
            for line in fh:
                if _FULL.match(line):
                    continue
                line = _INLINE.sub("", line).strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2 and parts[0] == "indicator-transport":
                    return parts[1]
    except OSError:
        pass
    return DEFAULT_TRANSPORT


def remote_argv(host, template=None):
    """host -> the argv that asks it for `mux agent-summary`.

    BUILT AS ARGV, never joined into a string: every delimiter is a bug waiting
    for a host name that contains it, and POSIX-shell latch learned the same
    lesson the hard way (`_run_transport` builds and runs in one function for
    exactly this reason).
    """
    out = []
    for word in shlex.split(template or transport()):
        if word == "%q":
            out.append(REMOTE_CMD)
        elif word == "%h":
            out.append(host)
        else:
            out.append(word.replace("%h", host))
    return out


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # exists, owned by someone else
    except (OSError, ValueError):
        return False
    return True


def latched(run_dir=None):
    """The hosts this box is currently latched to, from mux latch's locks.

    Returns [(host, target)], deduplicated: two latches to the same host (say
    `box:api` and `box:web`) are ONE tray item, because `mux agent-summary`
    answers for the whole box and two identical items would be a puzzle rather
    than information.
    """
    if run_dir is None:
        run_dir = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "mux-latch")
    try:
        names = sorted(os.listdir(run_dir))
    except OSError:
        return []
    out, seen = [], set()
    for name in names:
        if not name.endswith(".lock"):
            continue
        try:
            with open(os.path.join(run_dir, name)) as fh:
                pid = fh.readline().strip()
                target = fh.readline().strip()
        except OSError:
            continue
        if not pid.isdigit() or not _alive(int(pid)):
            continue         # a killed run is not a host worth polling
        if not target:
            continue         # a lock older than the two-line format
        # The target grammar: everything before the FIRST colon is the host, so
        # a session name may itself contain one.
        host = target.split(":", 1)[0]
        if not host or host in seen:
            continue
        seen.add(host)
        out.append((host, target))
    return out


def load(run_dir=None, mux_bin="mux"):
    """Every source to publish: this machine first, then each latched host.

    Local first because it is the one that is always there, so the tray's
    left-hand item does not move around as latches come and go.
    """
    local = local_label()
    out = [(local, [mux_bin, "agent-summary"])]
    tmpl = transport()
    for host, _target in latched(run_dir):
        if host == local:
            continue         # latched to ourselves: already the local item
        out.append((host, remote_argv(host, tmpl)))
    return out
