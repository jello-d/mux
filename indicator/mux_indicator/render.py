"""Owned, programmatically-drawn state glyphs -- no emoji font, no SVG raster
dependency. Shapes are drawn per size, so they stay crisp at any tray scale.

Each state renders to an SNI IconPixmap entry list: [[w, h, argb], ...], where
argb is ARGB32 in NETWORK (big-endian) byte order, i.e. bytes A,R,G,B per pixel,
as the StatusNotifierItem spec requires.

This is v1 placeholder art (simple shapes); it is deliberately the ONLY place
the visual identity lives, so richer owned glyphs slot in here without touching
the D-Bus plumbing.
"""
from PIL import Image, ImageDraw

# state -> RGBA fill. A small, owned palette (amber/blue/green/grey).
_PALETTE = {
    "blocked": (0xF2, 0xB0, 0x36, 0xFF),
    "working": (0x7A, 0xA2, 0xF7, 0xFF),
    "idle":    (0x9E, 0xCE, 0x6A, 0xFF),
    "none":    (0x88, 0x88, 0x88, 0xFF),
}
_INK = (0x14, 0x14, 0x14, 0xFF)


def _glyph(state, size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = _PALETTE.get(state, _PALETTE["none"])
    m = max(1, size // 8)
    w = max(2, size // 9)
    if state == "blocked":                       # warning triangle + bang
        d.polygon([(size // 2, m), (size - m, size - m), (m, size - m)], fill=c)
        d.line([(size // 2, int(size * 0.42)), (size // 2, int(size * 0.66))],
               fill=_INK, width=w)
        r = max(1, size // 16)
        cy = int(size * 0.76)
        d.ellipse([size // 2 - r, cy - r, size // 2 + r, cy + r], fill=_INK)
    elif state == "working":                     # filled dot
        d.ellipse([m, m, size - m, size - m], fill=c)
    elif state == "idle":                        # check mark
        d.line([(int(size * 0.24), int(size * 0.54)),
                (int(size * 0.42), int(size * 0.72)),
                (int(size * 0.76), int(size * 0.30))],
               fill=c, width=w, joint="curve")
    else:                                        # hollow ring
        rw = max(1, size // 10)
        d.ellipse([m, m, size - m, size - m], outline=c, width=rw)
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


def icon_pixmap(state, sizes=(22, 32, 48)):
    """SNI IconPixmap value for a state: a list of [w, h, argb-bytes]."""
    return [[s, s, _to_argb(_glyph(state, s))] for s in sizes]
