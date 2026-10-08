"""WHICH hosts the tray speaks for, discovered rather than configured.

THE BOX YOU ARE SITTING AT PULLS; nothing is pushed to it. Every
platform-specific decision then happens on that box, which is the only place it
belongs.

NO CONFIG FILE. The set is `mux latch`'s own lock directory, which is already a
live registry of what this box is attached to: `mux latch` writes
$XDG_RUNTIME_DIR/mux-latch/<target>.lock at start (pid on line 1, the target
verbatim on line 2, and since 0.56 the session on line 3) and removes it via a
trap on every exit path. So a host
appears in the tray when you latch to it and leaves when you detach, with
nothing to stand up, tear down, or keep in sync, and nothing to edit on each
machine. A second job for a file that already did it perfectly.

THE LOCAL HOST IS ALWAYS PRESENT and is not part of that choice: it is the
daemon's own box, it needs no transport, and showing it is what the indicator
did before it could do anything else.

A STALE LOCK IS NOT A HOST. The pid on line 1 is what makes a killed run
detectable, so a lock whose process is gone is skipped rather than polled:
otherwise a crashed latch would leave a permanent phantom in the tray, which is
exactly the "confidently reporting a host you cannot see" failure the whole
design exists to avoid.

SOURCES ARE STILL COMMANDS. The remote command is composed from a TEMPLATE, the
same seam shape as `latch-transport`, so ssh is a default and not a law: point
`desktop-notifier-transport` at anything that carries a command to a host. mux
specifies the shape of the answer, never the mechanism.
"""
import os
import re
import shlex
import shutil
import socket

# The comment rule is mux_conf_clean's, deliberately: a FULL-LINE comment goes,
# and an INLINE comment is WHITESPACE then #. A hash INSIDE a token survives, so
# a template containing one is safe. Kept identical to mux-conf_lib so a
# user who
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
#
# `-p %p:22` IS THE SAME GRAMMAR LATCH USES, not a second one: the port comes
# from the TARGET and the default from the TEMPLATE, because 22 being ssh's
# and 2022 being ET's is knowledge of a transport that mux does not have. A
# template with no `%p` never sees a port, so an older line still works.
DEFAULT_TRANSPORT = (
    "ssh -o BatchMode=yes -o ConnectTimeout=6 "
    "-o StrictHostKeyChecking=accept-new -p %p:22 %h %q"
)
# `mux agent status`, THE MACHINE CONTRACT, rather than the human-facing
# summary this used to poll. That is the whole point of the namespace: the
# tray is a program, so it reads the surface that promises a stable shape, and
# `mux agent-summary` stays free to change for whoever reads it in a terminal.
#
# ONE ROUND TRIP FOR EVERY PARTITION, which is what lets a host publish
# several items without multiplying its ssh traffic. A per-partition poll
# would be N queries per host per tick for an answer the far side composes in
# one, and a reader on another box cannot know the partition names to ask for
# in the first place.
#
# ATTACHED IS THE DEFAULT THERE, because A TRAY ITEM MEANS A HUMAN IS LOOKING
# AT THIS. For a remote host that is already what the latch registry encodes:
# an item exists only because a latch does, and the latch IS the human's
# live view of that box. The local counterpart is a client attached to that
# partition's server, and without it a partition with a live server and no
# terminal window showing it published an item nobody could act on.
#
# THE CONSEQUENCE IS DELIBERATE: detach from everything and the tray empties,
# because there is nothing anyone is looking at. That supersedes the older
# "the local host is always present" rule, which was written when a host had
# exactly one partition and presence WAS the question.
#
# `--all` IS EXPLICIT, AND WAS LOAD-BEARING BEFORE IT WORKED. Until 0.73 the
# flag was parsed and never read, so every caller got every partition and this
# daemon depended on that by accident; scoping the verb to the caller's
# partition (which is what its own documentation promised) would have quietly
# reduced a remote host to whichever partition its login shell resolves,
# exactly the blindness 0.56 existed to fix. An older mux on the far side
# ignores the flag and still answers for everything, so it is safe to send.
REMOTE_CMD = "sh -lc 'mux agent status --all'"
LOCAL_CMD = ("agent", "status", "--all")
# THE STREAMING FORM OF THE SAME QUESTION. `mux agent stream` emits the SAME
# document one line at a time and only when something changes, so a watcher
# stops asking: the polling happens on the watched box and only CHANGES cross
# the network. Same flags, because it is the same question.
LOCAL_STREAM = ("agent", "stream", "--all")
# And over a transport. `sh -lc` for the reason REMOTE_CMD needs it: sshd runs
# a remote command WITHOUT a login shell, so mux is not on PATH without it.
REMOTE_STREAM = "sh -lc 'mux agent stream --all'"

# A partition name is a DNS label (see mux_ctx_valid): lowercase alphanumerics
# and hyphens. VALIDATED HERE because the names arrive from the far side and
# go back out inside a shell command, so this is untrusted input crossing into
# `sh -lc`, not a second copy of mux's rule, which decides what a partition
# may be CALLED rather than what this daemon may quote.
_PART_OK = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def valid_partition(name):
    return bool(name) and bool(_PART_OK.match(name))


def activate_cmd(part=None):
    """The click's remote half. `mux next-blocked` resolves its own client
    when it has no pane to read one from (mux 0.53), which is the whole reason
    a tray click can reach a latched host at all.

    THE PARTITION TRAVELS WITH IT, or every item on a host does the same
    thing: the far side's login shell resolves its own default and jumps
    there, landing on a real session that is not the one clicked.
    """
    if part and valid_partition(part):
        return f"sh -lc 'mux next-blocked --partition {part}'"
    return "sh -lc 'mux next-blocked'"


def local_label():
    """This machine's short hostname: the local item's label, and the token
    `mux host-color` hashes, so a FQDN here would colour the tray differently
    from the status bar."""
    return socket.gethostname().split(".")[0] or "local"


def _mux_dir():
    return os.environ.get("MUX_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME")
        or os.path.join(os.path.expanduser("~"), ".config"), "mux")


def _conf(key):
    """A directive from $MUX_DIR/config, or None.

    ONE READER, because there are two keys now and a second copy of the
    comment-stripping would be a second place for it to drift. mux's config
    grammar is the whole file's business, not any one directive's.
    """
    try:
        with open(os.path.join(_mux_dir(), "config")) as fh:
            for line in fh:
                if _FULL.match(line):
                    continue
                line = _INLINE.sub("", line).strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2 and parts[0] == key:
                    return parts[1]
    except OSError:
        pass
    return None


def transport():
    """The remote-command template: env, then $MUX_DIR/config, then the default.
    The same environment-over-config-over-shipped order every mux seam uses."""
    return (os.environ.get("MUX_DESKTOP_NOTIFIER_TRANSPORT")
            or _conf("desktop-notifier-transport") or DEFAULT_TRANSPORT)


# Partitions this daemon says nothing about, on either surface. SHIPPED
# NON-EMPTY, which is a shipped DEFAULT and so wants justifying against this
# tree's own rule that one which cannot succeed everywhere is worse than none:
# this names BEHAVIOUR rather than a location, it is correct on every machine,
# and it is one line to turn off. `mux demo` drives four pretend agents
# through the real machinery for ever, so without it a demo fills the
# notification daemon with news about sessions that do not exist. That used to
# be suppressed by an env pair the demo exported into the hook it invoked, and
# that mechanism is structurally gone: the raiser is now a separate long-lived
# process no demo can reach.
DEFAULT_IGNORE = ("mux.demo",)


def ignored():
    """Partition names to say nothing about, as a frozenset.

    Env, then `$MUX_DIR/config`, then the shipped default: the same
    environment-over-config-over-shipped order every mux seam uses.

    `none` IS THE EMPTY SET, rather than an empty value, for the reason
    `latch-fallback none` already exists: a key present but blank is
    indistinguishable from a key absent in a line-oriented config, so "ignore
    nothing" needs a word. That word is how somebody watching the demo turns
    its banners ON, which is the whole reason this is a filter rather than a
    hardcoded refusal: a validation could not be opted out of.
    """
    raw = (os.environ.get("MUX_DESKTOP_NOTIFIER_IGNORE")
           or _conf("desktop-notifier-ignore"))
    if raw is None:
        return frozenset(DEFAULT_IGNORE)
    names = [w for w in raw.replace(",", " ").split() if w]
    if len(names) == 1 and names[0] == "none":
        return frozenset()
    return frozenset(names)


def activate_hook():
    """What to run LOCALLY after a click, or None. Env, then config, UNSET.

    THE SEAM EXISTS BECAUSE THE USEFUL HALF IS NOT MUX'S. Clicking a tray item
    switches that host's tmux client to whatever needs you, but if the
    terminal showing it is behind three windows or on another workspace, the
    switch is invisible and the click feels broken. Raising that window means
    knowing about a compositor, and mux does not get to know about compositors:
    it manages sessions inside terminals and has no opinion about where a
    terminal sits. That boundary is already written down here in blood, from
    the time window placement was chased into wayfire's config and turned out
    to be usher's job.

    So mux specifies the SHAPE of the answer and the integrator supplies the
    mechanism, exactly as context-command already does. The
    hook is handed the LABEL as its one argument.

    UNSET BY DEFAULT, and that is the third answer rather than a missing one:
    nobody asked for a focus change, so none happens, and the click still does
    the part mux legitimately owns.
    """
    return (os.environ.get("MUX_DESKTOP_NOTIFIER_ACTIVATE")
            or _conf("desktop-notifier-activate"))


def share_dir():
    """The shipped `share/` tree, or None.

    `$MUX_SHARE` when it names a real directory, else DERIVED from the `mux`
    on PATH exactly the way bin/mux locates its own siblings: resolve the
    symlink, and share is the sibling of bin under the same prefix.

    THE DAEMON IS NOT STARTED BY mux, which is why deriving is necessary at
    all: it is a --user unit with a PATH and nothing else, so it inherits no
    MUX_SHARE and has to find the tree the same way its own installer laid it
    out.
    """
    env = os.environ.get("MUX_SHARE")
    if env and os.path.isdir(env):
        return os.path.normpath(env)
    exe = shutil.which(os.environ.get("MUX_BIN", "mux"))
    if not exe:
        return None
    root = os.path.dirname(os.path.dirname(os.path.realpath(exe)))
    # NORMALISED, so a resolved hook reads as a path rather than as
    # `.../bin/../share/...` in every log line and failure message.
    cand = os.path.normpath(os.path.join(root, "share"))
    return cand if os.path.isdir(cand) else None


def hook_path(value):
    """A hook NAME resolved to a path: the user's overlay, then the shipped
    one, else left alone for PATH to answer.

    IT EXISTED FOR latch AND NOT HERE, which made the shipped samples
    unreachable: `desktop-notifier-activate focus-kitty` is what config.sample
    documents, `focus-kitty` is NOT on PATH, and it installs under
    `$MUX_SHARE/desktop-notifier/`. So the one spelling the documentation
    teaches could not resolve, and the click reported "failed to start"
    naming a file the user can see on disk. Advice that cannot come true, in
    the form of a sample nobody could name.

    THE SAME THREE CASES AS latch's `_hook`, deliberately, so a reader who
    knows one knows the other: a value containing `/` is a literal path and
    is never searched for, `none` disables the seam, and anything else is a
    bare name resolved overlay-first. Only the leading WORD is resolved, so a
    hook may carry arguments.
    """
    if not value:
        return value
    if value == "none":
        return None
    name = value.split(" ", 1)[0]
    rest = value[len(name):]
    if "/" in name:
        return value
    for base in (_mux_dir(), share_dir()):
        if not base:
            continue
        cand = os.path.join(base, "desktop-notifier", name)
        if os.access(cand, os.X_OK):
            return cand + rest
    return value


def toast_hook():
    """What composes a banner, or None for the built-in wording.

    UNSET BY DEFAULT, AND THE DEFAULT IS DELIBERATELY PLAIN. Which field a
    notification daemon renders, and whether it interprets markup in it, is
    the DAEMON's choice: mako reads Pango in the body and not in the summary,
    dunst differs, a macOS presenter will have no Pango at all. So mux emits
    text that reads correctly everywhere and offers this seam to anyone who
    wants their own. Styling shipped as the default would make the daemon
    mako-specific in exactly the way kitty's OSC 99 was rejected for.

    THE CONTRACT IS ONE STREAM, SPLIT ONCE: the hook prints the SUMMARY on
    the first line and the BODY on every line after it. That is what lets a
    hook put the line break where it wants, which is the whole point for a
    format that joins summary and body on one row.
    """
    return hook_path(os.environ.get("MUX_DESKTOP_NOTIFIER_TOAST")
                     or _conf("desktop-notifier-toast"))


def remote_argv(host, template=None, cmd=None, port=None):
    """host -> the argv that asks it for `mux agent status`.

    THE PORT WAS SILENTLY DROPPED UNTIL NOW, which is the gap this closes: the
    lock's address carries `HOST[:PORT]`, the caller split it off to key the
    item by host, and nothing put it back. So a latch to `box:2222` was
    WATCHED AT 22: a tray item that reads `unknown` forever about a box that
    is perfectly reachable, or worse, a different box answering on 22.

    BUILT AS ARGV, never joined into a string: every delimiter is a bug waiting
    for a host name that contains it, and POSIX-shell latch learned the same
    lesson the hard way (`_run_transport` builds and runs in one function for
    exactly this reason).
    """
    out = []
    for word in shlex.split(template or transport()):
        if word == "%q":
            out.append(cmd or REMOTE_CMD)
            continue
        # `%p:DEFAULT` before bare `%p`, because the first contains the
        # second: substituting `%p` first would leave the `:22` behind as
        # part of the argument and ask ssh for port `22222`.
        m = re.search(r"%p:(\d+)", word)
        if m:
            word = word.replace(m.group(0), port or m.group(1))
        elif "%p" in word:
            # EMPTY WHEN THERE IS NO PORT, which is exactly what latch does
            # with the same token, and one grammar is the entire argument for
            # mirroring it. Dropping the WORD instead was my first version and
            # it is the worse failure: `-p` and `%p` are separate shell words,
            # so dropping one leaves its flag to swallow the next argument and
            # `ssh -p box` dials nothing while looking like a dial. A bare
            # `%p` with no port is a misconfigured template, and ssh refusing
            # an empty port says so.
            word = word.replace("%p", port or "")
        if word == "%h":
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
        # The ADDRESS grammar, `HOST[:PORT]`, which is all line 2 carries
        # since 0.84: the partition and session moved out of it, so a colon
        # here can only be a port.
        host, port = split_address(target)
        if not host or host in seen:
            continue
        seen.add(host)
        out.append((host, target))
    return out


def split_address(addr):
    """`HOST[:PORT]` -> (host, port or None).

    AN IPv6 LITERAL IS NEVER SPLIT, the same rule latch applies to the same
    field: a colon is a port only when it cannot be anything else, meaning one
    colon with digits after it, or brackets. `fe80::1` survives whole, and
    getting this wrong dials a host that does not exist while looking like it
    worked, which is this package's signature failure.
    """
    if not addr:
        return "", None
    if addr.startswith("["):
        end = addr.find("]")
        if end > 0:
            rest = addr[end + 1:]
            if rest.startswith(":") and rest[1:].isdigit():
                return addr[1:end], rest[1:]
            return addr[1:end], None
        return addr, None
    if addr.count(":") == 1:
        h, _, p = addr.partition(":")
        if p.isdigit():
            return h, p
    return addr, None


def _hosts(run_dir=None):
    """The labels to publish, in order: this machine, then each latched host.

    Local first because it is the one that is always there, so the tray's
    left-hand item does not move around as latches come and go. Latched to
    ourselves is skipped: that is already the local item.

    Each is `(label, address)`: the ADDRESS is carried rather than discarded
    because it holds the PORT, and dropping it is exactly the bug this pair
    shipped: the item was keyed by host, the port was split off to do that,
    and nothing put it back.

    ONE ENUMERATION FOR BOTH `load` AND `streams`, because the moment the two
    disagree about WHICH hosts exist, a host gets a poll and a stream at once
    or neither, and the tray's own rule is that the answer which repaints the
    items is also the one that decides which items exist.
    """
    local = local_label()
    out = [(local, "")]
    for host, target in latched(run_dir):
        if host != local:
            out.append((host, target))
    return out


def load(run_dir=None, mux_bin="mux"):
    """Every source to publish, as label -> the argv that QUERIES it once."""
    tmpl = transport()
    local = local_label()
    return [(h, [mux_bin, *LOCAL_CMD] if h == local
             else remote_argv(h, tmpl, port=split_address(a)[1]))
            for h, a in _hosts(run_dir)]


def streams(run_dir=None, mux_bin="mux"):
    """label -> the argv that STREAMS that source, for sources that can.

    SEPARATE FROM `load()` RATHER THAN A THIRD FIELD IN ITS TUPLES, for two
    reasons. `load()`'s shape is consumed as pairs in several places, and
    widening it would change every one of them to buy nothing. And the set of
    sources that can be streamed is going to GROW: the remote half needs a
    connection it can share before a stream over it is cheaper than a poll, so
    "which sources stream" wants one explicit place to say so rather than a
    condition spread across the loader.

    EVERY SOURCE STREAMS NOW, local and remote alike, and the remote half is
    what the whole design was for: the box the human is sitting at stops
    asking every host every five seconds, and a transition crosses the network
    when it HAPPENS rather than up to a poll later. That is also the thing
    that makes a remote notification possible at all.

    A STREAM IS CHEAPER THAN THE POLL IT REPLACES, and that is worth stating
    because the reverse was assumed while designing this: the argument for
    sharing a connection (ControlMaster) was amortising a handshake paid every
    five seconds, and a stream pays ONE handshake and then holds it. Sharing
    may still be worth it for a faster reconnect; it is no longer a
    precondition, so it is not done here.

    WHETHER A SOURCE CAN ACTUALLY STREAM IS NOT KNOWABLE HERE. A remote may be
    running a mux too old to know the verb, and this function cannot ask
    without a round trip per host at every discovery pass. The reader finds
    out instead, and falls back to polling that host: see `Feed.watch`.
    """
    tmpl = transport()
    local = local_label()
    return [(h, [mux_bin, *LOCAL_STREAM] if h == local
             else remote_argv(h, tmpl, REMOTE_STREAM,
                              port=split_address(a)[1]))
            for h, a in _hosts(run_dir)]
