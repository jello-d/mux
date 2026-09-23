"""WHERE the indicator gets state, and for WHICH hosts.

THE BOX YOU ARE SITTING AT PULLS; nothing is pushed to it. Every
platform-specific decision then happens on that box, which is the only place it
belongs -- and it is what makes a macOS tray a presenter swap rather than a new
transport.

SOURCES ARE COMMANDS, NOT HOSTS. The same seam shape as `context-command` and
`MUX_NOTIFY_SEND`: mux specifies the shape of the ANSWER, never the mechanism.
So a line is `LABEL COMMAND...` and it works over ssh, a jump host, `kubectl
exec`, anything. The indicator never learns what ssh is.

    manifestor  ssh manifestor mux agent-summary
    manifold    mux agent-summary

THE LABEL IS LOAD-BEARING, and it does three jobs: it names the host in the
tooltip, it keys the colour (`mux host-color LABEL`, so a remote host is
coloured the same as its status-bar chip with nothing shared between machines),
and it becomes the tray id `mux-<label>` so a bar can order items and a human
reading the D-Bus name list can tell which item speaks for which host.

THE DEFAULT IS THIS MACHINE. With no file, one source labelled with the local
hostname running `mux agent-summary` -- which is what the indicator did before
it could do more, so an existing install gains a name and loses nothing.
"""
import os
import re
import shlex
import socket

# The comment rule is mux_conf_clean's, deliberately: a FULL-LINE comment goes,
# and an INLINE comment is WHITESPACE then #. A hash INSIDE a token survives, so
# a command containing one is safe. Kept identical to mux-conf.sh so a user who
# knows one config file knows this one.
_FULL = re.compile(r"^\s*#")
_INLINE = re.compile(r"\s#.*$")


def local_label():
    """This machine's short hostname: the default label, and the one `mux
    host-color` will resolve to the same chip colour the status bar uses."""
    return socket.gethostname().split(".")[0] or "local"


def parse(text):
    """Source text -> [(label, argv), ...], skipping anything unusable.

    A malformed line is DROPPED rather than raised on. This file is read by a
    tray daemon at startup: refusing to start because one of five hosts has a
    typo would take away the four that are fine, which is the opposite of what
    a status indicator is for.
    """
    out = []
    for line in text.splitlines():
        if _FULL.match(line):
            continue
        line = _INLINE.sub("", line).strip()
        if not line:
            continue
        try:
            parts = shlex.split(line)
        except ValueError:
            continue          # an unbalanced quote is not a source
        if len(parts) < 2:
            continue          # a label with no command answers nothing
        out.append((parts[0], parts[1:]))
    return out


def load(path=None, mux_bin="mux"):
    """The configured sources, else the single local default.

    Resolution order is MUX_INDICATOR_SOURCES, then $MUX_DIR/indicator-sources,
    then the default -- the environment-over-config-over-shipped precedence
    every other mux seam uses.
    """
    if path is None:
        path = os.environ.get("MUX_INDICATOR_SOURCES")
    if path is None:
        mux_dir = os.environ.get("MUX_DIR") or os.path.join(
            os.environ.get("XDG_CONFIG_HOME")
            or os.path.join(os.path.expanduser("~"), ".config"), "mux")
        path = os.path.join(mux_dir, "indicator-sources")
    try:
        with open(path) as fh:
            got = parse(fh.read())
    except OSError:
        got = []
    # An EMPTY file falls back too, not just a missing one. A file that exists
    # and lists nothing usable would otherwise start a tray daemon with no
    # items at all -- indistinguishable, from the bar, from a crashed daemon.
    return got or [(local_label(), [mux_bin, "agent-summary"])]
