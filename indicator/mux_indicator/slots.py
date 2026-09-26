"""Which palette slot a remote host's mark wears.

NAME-SEEDED, BUMPED ONLY ON COLLISION, THEN STICKY. Those are three separate
decisions and each one is answering a complaint about the other two:

- SEEDED BY NAME, because a purely first-come rule makes the colour depend on
  the order you happened to latch. Walk to the other machine, latch in a
  different order, and the same host is a different colour -- which is exactly
  the property that makes you stop trusting the hint. Seeding means that on any
  box where your hosts do not collide, every host is the same colour on every
  box, with nothing shared and nothing to sync.
- BUMPED ON COLLISION, because a derived rule alone cannot promise distinctness
  and distinctness is the entire point. Two names landing on one slot is not
  hypothetical: `manifold` and `manifestor` already derive the same status-bar
  pair. The bump is confined to the hosts that actually collide, which is
  precisely where the derived rule was already broken.
- STICKY, because a bump computed from the live set would move when the set
  moves: latch a third host and the second one's colour changes underneath you.
  Once a host has a slot it keeps it, and the record outlives the daemon.

WHAT THIS DELIBERATELY DOES NOT DO is agree with `mux host-color`. The tray
palette is five wide because STATE owns the warm and green hues on a tile; the
status bar has no such constraint and carries the host NAME in text beside the
chip, so colour there is decoration and here it is load-bearing. Constraining
the decorative channel to serve the load-bearing one is backwards. The two
surfaces already share the one identifier that IS stable everywhere: the three
letters of the mark.
"""
import os
import zlib

# `hash()` IS SALTED PER PROCESS in Python 3, so it would reassign every slot
# on restart and quietly defeat the whole file. crc32 is stable across runs,
# versions and machines, which is the only property being asked of it.
_SEED = zlib.crc32


def state_dir():
    """mux's own state directory. STATE, not cache: an assignment cannot be
    rebuilt once the order that produced it is gone, which is the same test
    mux-paths.sh applies to the session set."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser(
        "~/.local/state")
    return os.path.join(base, "mux")


def store_path():
    return os.path.join(state_dir(), "indicator-slots")


def _load(path):
    """-> {name: slot}. A damaged line is SKIPPED, not fatal: the cost of one
    unreadable record is one host getting a fresh slot, and refusing to start
    over a corrupt cosmetic file would be the worse failure."""
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # SLOT FIRST, NAME LAST, so a name containing a space reads
                # back whole -- the same field order, for the same reason, as
                # mux's per-pane agent record.
                bits = line.rstrip("\n").split(None, 1)
                if len(bits) != 2 or not bits[0].isdigit():
                    continue
                out[bits[1]] = int(bits[0])
    except OSError:
        pass
    return out


def _save(path, table):
    """Best effort, and atomic where it lands. A failed write costs stickiness
    across restarts and nothing else, so it must never raise into the poll
    loop that called it."""
    tmp = f"{path}.{os.getpid()}"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            for name, slot in sorted(table.items(), key=lambda kv: kv[1]):
                fh.write(f"{slot} {name}\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


class Slots:
    """Hands out palette slots and remembers what it handed out."""

    def __init__(self, width, path=None):
        self.width = width
        self.path = store_path() if path is None else path
        self.table = _load(self.path)

    def preferred(self, name):
        return _SEED(name.encode("utf-8", "replace")) % self.width

    def slot(self, name):
        """-> the slot for `name`, assigning and persisting one if new."""
        if name in self.table:
            return self.table[name]
        want = self.preferred(name)
        taken = set(self.table.values())
        slot = want
        for step in range(self.width):
            cand = (want + step) % self.width
            if cand not in taken:
                slot = cand
                break
        # Falling out of that loop means every slot is held, so `slot` stays at
        # the seeded one and two hosts share a hue. See render.mark_ink().
        self.table[name] = slot
        _save(self.path, self.table)
        return slot

    def forget(self, names):
        """Drop every recorded host NOT in `names`.

        Nothing calls this on a detach, on purpose: stickiness is the feature,
        and a host you unlatch for an afternoon must come back the colour you
        learned. It exists so the record cannot grow without bound over years
        of one-off hosts, and so there is a way to deliberately reshuffle.
        """
        keep = {n: s for n, s in self.table.items() if n in names}
        if keep != self.table:
            self.table = keep
            _save(self.path, self.table)
