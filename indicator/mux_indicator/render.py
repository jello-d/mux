"""Owned tray glyphs -- no emoji font, no SVG raster dep. Drawn per size so they
stay crisp at any tray scale.

The icon is a terminal (mux is a terminal thing): a near-black rounded tile with
a big, tall `>_` prompt as the hero, drawn in a light grey LIFTED off the screen
(ornamental, but present -- attention still belongs to the frame and badge). Its
brightness tracks the screen so it reads the same on every state's tint. The `_`
cursor is BLINKABLE (render with cursor=False for the off frame). STATE is the
frame colour + a subtle
same-hue tint in the screen, MATCHING mux's own status chips so the two read as
one system: blocked = orange, working = pink (the brain), idle = green, none =
grey. The BADGE is a related-but-distinct pop that overhangs the corner:
crimson (blocked) and purple (working) hold the count; idle holds a white check
in a bright-green badge; none shows nothing. render.py is the ONLY place the
visual identity lives.

Each state+count renders to an SNI IconPixmap entry list [[w, h, argb], ...],
argb being ARGB32 in NETWORK (big-endian) byte order per the StatusNotifierItem
spec.
"""
from PIL import Image, ImageDraw, ImageFont

# Frame colour + tint hue per state, keyed off mux's agent-state chips.
STATE_FRAME = {
    "blocked": (0xFF, 0xB0, 0x20, 0xFF),   # amber-gold -- warm, off the purple
    "working": (0xFF, 0x8C, 0xE6, 0xFF),   # bright magenta/pink border
    "idle":    (0x34, 0xC9, 0x4A, 0xFF),   # green (= the badge green)
    "none":    (0x88, 0x88, 0x8E, 0xFF),   # grey (agentless)
    # UNKNOWN IS NOT CALM, and this row is the whole reason it exists. A source
    # that could not be reached says NOTHING about that host -- it may be idle,
    # it may have six blocked agents. Falling back to `none` (which is what an
    # unrecognised state used to do) would draw a quiet grey tile and assert the
    # one thing we do not know. Slate blue, deliberately outside the
    # blocked/working/idle hue family: it must not read as an agent state at
    # all, because it is a statement about the CONNECTION.
    "unknown": (0x6C, 0x7A, 0x9C, 0xFF),   # slate blue (unreachable)
}
# Badge colour per state -- related to the frame, distinct from it. `none` is
# absent -> no badge. idle's badge holds a white check, not a number.
STATE_BADGE = {
    "blocked": (0xC0, 0x18, 0x28, 0xFF),   # bold red -- urgent, less black
    "working": (0x5F, 0x00, 0xD7, 0xFF),   # mux chip bg colour56 (purple)
    "idle":    (0x25, 0xA8, 0x3A, 0xFF),   # green, a drop darker for contrast
    # A badge, because `none` has none: that difference is what stops "no agents
    # here" and "cannot see this host" drawing the same tile. It holds a `?`
    # rather than a count -- there is no count to hold.
    "unknown": (0x3A, 0x44, 0x5C, 0xFF),   # dark slate, same family as frame
}
# Number/check colour per state -- chosen for contrast on the badge, echoing the
# frame hue: amber (= frame) on the dark-red block badge, deep purple on the
# bright-pink work badge, white for the idle check.
STATE_INK = {
    "blocked": (0xFF, 0xF6, 0xA8, 0xFF),   # light yellow, pops on red
    "working": (0xFF, 0xE2, 0xBC, 0xFF),   # warm peach, a drop brighter
    "idle":    (0xF4, 0xF4, 0xF6, 0xFF),   # white check
    "unknown": (0xC8, 0xD2, 0xE8, 0xFF),   # pale slate, reads on the dark badge
}
_BASE = (0x14, 0x15, 0x19)           # near-black screen
_PROMPT_LIFT = 0.55  # how far the ornamental >_ lifts from the screen toward
                     # white; higher = brighter/less recessive. Derived off the
                     # (state-tinted) screen so contrast tracks every state.
_CURSOR_LIFT = 0.30  # the _ cursor lifts this much further from the prompt
                     # colour toward white, so it reads a touch brighter than
                     # the > chevron.
_BADGE_INK = (0xF4, 0xF4, 0xF6, 0xFF)    # white count on the badge
_SHADOW = (0, 0, 0, 120)

# Geometry, as fractions of the icon size.
_BADGE_F = 0.65    # badge diameter (overhangs the corner)
_MARGIN = 0.0      # tile inset as a fraction; 0 = frame fills the tile
_NUM = 1.10        # badge number, blown up to fill / clip the round badge
_TINT = 0.14       # how much state hue bleeds into the near-black screen
# The host's bg is a STATUS-BAR chip colour, picked to sit behind text on a bar
# -- so at full strength it would make a bright tray tile that reads as a
# different application, not a different host. Mixed well into the near-black
# base instead: unmistakable side by side, still obviously a terminal.
_HOST_TINT = 0.55
_TRACK = 0.28      # inter-digit tracking to pull, e.g., "12" tighter

_SANS = ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
         "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf")


def _font(paths, px):
    for p in paths:
        try:
            return ImageFont.truetype(p, px)
        except OSError:
            continue
    return ImageFont.load_default()


def _darker(c, f):
    return tuple(int(c[i] * f) for i in range(3)) + (0xFF,)


def parse_pair(text):
    """`mux host-color` output -> ((fg), (bg)) as RGBA, or None.

    WHY MUX ANSWERS THIS AT ALL: a per-host tray item has to be the same colour
    as that host's status-bar chip, or the two disagree about which machine is
    which and neither looks broken. So the rule has ONE owner (mux-hosts.sh,
    which `mux style` also uses) and this only converts.

    None on anything unexpected, INCLUDING the refusal. `mux host-color` exits 1
    for colours 0-15 -- the terminal's own sixteen, which every theme remaps, so
    there is no correct hex -- and the right answer to that is to draw the
    host-neutral look, not to guess a colour for the thing whose whole job is
    identifying a machine.
    """
    parts = text.split()
    if len(parts) != 2:
        return None
    out = []
    for tok in parts:
        if len(tok) != 7 or not tok.startswith("#"):
            return None
        try:
            v = int(tok[1:], 16)
        except ValueError:
            return None
        out.append(((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, 0xFF))
    return (out[0], out[1])


def _screen(state, host=None):
    """The tile's screen. WITH a host pair this is the host's BACKGROUND, which
    is literally what that colour is for -- so identity reads at a glance while
    STATE keeps the frame and the badge. The two dimensions never collide:
    nothing about the host can make a blocked agent look calm.

    The state tint is dropped when a host colour is in play rather than mixed
    with it. Two hues bleeding into one screen is how both become unreadable,
    and state is already carried twice over (frame + badge)."""
    if host is not None:
        return _mix(_BASE, host[1], _HOST_TINT)
    col = STATE_FRAME.get(state, STATE_FRAME["none"])
    return _mix(_BASE, col, _TINT)


def _prompt(state, host=None):
    """The ornamental >_ colour.

    WITH a host pair this is the host's FOREGROUND, and that pairing is the
    whole reason to use mux's own colours rather than deriving something here:
    the pair EXISTS so that fg is legible on bg (mux's own suite asserts they
    are never equal), so `>_` on the screen is guaranteed readable for free. A
    lift heuristic would have to re-derive that property and could get it wrong
    on a pale host colour.

    Without one, the old rule: the state's screen lifted toward white, so the
    prompt sits a consistent step above whatever tint the state paints."""
    if host is not None:
        return host[0]
    scr = _screen(state)
    return _mix(scr, (0xFF, 0xFF, 0xFF), _PROMPT_LIFT)


def _mix(a, b, f):
    """b blended into a by f. Was open-coded three times over once the host
    pair arrived, which is exactly when a two-line helper starts paying."""
    return tuple(int(a[i] * (1 - f) + b[i] * f) for i in range(3)) + (0xFF,)


def _number(d, box, text, fnt, fill):
    # Digits centered in the badge, with tightened inter-digit tracking so a
    # two-digit count reads as one unit rather than two loose glyphs.
    advs = [d.textlength(c, font=fnt) for c in text]
    gap = _TRACK * (sum(advs) / len(text))
    total = sum(advs) - gap * (len(text) - 1)
    _, t, _, b = d.textbbox((0, 0), text, font=fnt)
    x = box[0] + (box[2] - box[0] - total) / 2
    y = box[1] + (box[3] - box[1] - (b - t)) / 2 - t
    for i, c in enumerate(text):
        d.text((x, y), c, font=fnt, fill=fill)
        x += advs[i] - gap


def _hero(d, s, m, col, cursor=True):
    # A TALL custom '>' chevron (the font's is too squat) + an underscore cursor
    # to its RIGHT. The chevron is the prompt colour; the cursor is lifted a
    # touch brighter (_CURSOR_LIFT). The cursor is drawn only when `cursor` is
    # set, so a caller can blink it.
    th = max(2, int(s * 0.11))
    top = int(s * 0.30)
    bot = s - m - int(s * 0.20)
    x, w = int(s * 0.18), int(s * 0.20)
    d.line([(x, top), (x + w, (top + bot) / 2), (x, bot)],
           fill=col, width=th, joint="curve")
    if not cursor:
        return
    cur = tuple(int(col[i] * (1 - _CURSOR_LIFT) + 0xFF * _CURSOR_LIFT)
                for i in range(3)) + (0xFF,)
    cx = x + w + int(s * 0.12)
    cw, ch = int(s * 0.28), max(2, int(s * 0.09))      # wider underscore
    rlim = s - m - int(s * 0.14)
    d.rectangle([cx, bot - ch, min(cx + cw, rlim), bot], fill=cur)


def _badge(img, s, fill, ink, count, check=False, mark=None):
    bd = int(s * _BADGE_F)
    x0 = s - bd
    box = [x0, -1, s - 1, bd - 1]
    off = max(1, s // 22)
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [x0 + off, -1 + off, s - 1 + off, bd - 1 + off], fill=_SHADOW)
    img.alpha_composite(shadow)
    d = ImageDraw.Draw(img)
    edge = _darker(fill, 0.62)
    d.ellipse(box, fill=fill, outline=edge, width=max(1, s // 30))
    # THE CHECK IS KEYED ON THE STATE, NOT ON A MISSING COUNT, and the
    # difference is not academic. This used to read `if count is None`, which
    # made two silent mistakes possible:
    #
    #   `idle` WITH a count drew the NUMBER -- a tray icon reading `idle 4`,
    #   which looks like four things needing attention when the truth is the
    #   opposite. It never happened only because _parse() normalises idle's
    #   count away, so the invariant lived in the PARSER rather than here.
    #
    #   `blocked` with an UNREADABLE count (`_parse` yields None for `-` or a
    #   non-numeric field) drew the CHECK -- the calmest glyph there is, on the
    #   loudest state.
    #
    # Now: idle draws the check because it is idle. Any other state draws its
    # number when it has one, and a BARE badge when it does not -- honest about
    # "something is happening, how much is unknown" rather than claiming calm.
    if check:
        r = bd
        d.line([(x0 + r * 0.28, (bd - 1) / 2),
                ((x0 + s - 1) / 2, bd - 1 - r * 0.20),
                (s - 1 - r * 0.14, r * 0.10 - 1)],
               fill=ink, width=max(2, s // 9), joint="curve")
    elif mark is not None:
        # A literal glyph (`?` for unknown), drawn through the same centring
        # path as a count so it lands identically -- the badge geometry has one
        # owner, not two.
        _number(d, box, mark, _font(_SANS, int(bd * _NUM)), ink)
    elif count is not None:
        _number(d, box, str(count), _font(_SANS, int(bd * _NUM)), ink)


def _tile(state, count, size, cursor=True, host=None):
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    frame = STATE_FRAME.get(state, STATE_FRAME["none"])
    m = max(0, round(s * _MARGIN))
    d.rounded_rectangle([m, m, s - 1 - m, s - 1 - m], max(2, s // 7),
                        fill=_screen(state, host), outline=frame,
                        width=max(1, s // 11))
    _hero(d, s, m, _prompt(state, host), cursor)
    bcol = STATE_BADGE.get(state)
    if bcol is not None:              # blocked/working (number), idle (check)
        _badge(img, s, bcol, STATE_INK.get(state, _BADGE_INK), count,
               check=(state == "idle"),
               mark="?" if state == "unknown" else None)
    return img


def _to_argb(img):
    rgba = img.tobytes("raw", "RGBA")
    out = bytearray(len(rgba))
    for i in range(0, len(rgba), 4):
        out[i] = rgba[i + 3]      # A
        out[i + 1] = rgba[i]      # R
        out[i + 2] = rgba[i + 1]  # G
        out[i + 3] = rgba[i + 2]  # B
    return bytes(out)


def icon_pixmap(state, count, sizes=(22, 32, 48), cursor=True, host=None):
    """SNI IconPixmap for a state + count. idle/none draw no badge. cursor=False
    renders the blink OFF frame (the `_` cursor hidden).

    `host` is an (fg, bg) RGBA pair from parse_pair() -- the host's identity
    colours, which tint the screen and paint the `>_`. None draws the
    host-neutral look, which is both the single-host default and the honest
    answer when `mux host-color` refuses."""
    return [[s, s, _to_argb(_tile(state, count, s, cursor, host))]
            for s in sizes]
