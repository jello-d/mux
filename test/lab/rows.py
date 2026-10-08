#!/usr/bin/env python3
"""Count the TEXT ROWS in a screenshot of a notification, and how bright
each one is.

NOT EXECUTABLE, AND THE SUFFIX STAYS, which is the house rule read the right
way round rather than an exception to it. The rule is that a file EXECUTED as
a unit takes a bare name; these are handed to an interpreter the caller
already names (`python3 rows.py`), so they are arguments rather than
commands. Keeping the suffix is then what tells a reader and an editor what
they are, and the +x bit was simply wrong: it claimed a way of being run that
nothing uses.

WHY PIXELS AT ALL. mux's toast hooks print two fields and a daemon's format
decides where the line break lands, so "how many rows did the user get" is
the only statement of the contract that is actually about what they see.
This repo measured it once with `pango-view`, which renders the same markup
with the same library and is therefore a good proxy and not the thing: it
cannot show that the daemon substituted %s and %b where we think, nor that
it parses markup in the body and not the summary.

THE MEASUREMENT IS A BAND PROFILE, not OCR, and that is deliberate. OCR
would introduce a dependency whose failures look like the product's, and the
questions worth asking are all structural:

    how many rows of ink are there       2, 3, or 3-with-a-gap
    is one of them DIMMER than another   which is what `<span fg=...>` buys

A row is a maximal run of scanlines holding ink; a gap is a run holding
none. So a blank line between two text lines shows up as a gap TALLER than
the gaps between rows of the same paragraph, which is exactly the difference
between `toast/pango` under a joining format and under a default one.

INK IS ANY PIXEL ABOVE A FLOOR, against the known background the lab's
compositor is configured to paint. The floor is generous (any channel over
0x30) because antialiasing puts a lot of nearly-black pixels around a glyph
and counting those as ink is what makes a row's extent stable.
"""
import json
import sys

try:
    from PIL import Image
except ImportError:                                   # pragma: no cover
    print("rows.py: Pillow is not installed", file=sys.stderr)
    sys.exit(78)

INK = 0x30          # any channel above this is ink, not background
MIN_ROW = 2         # a row thinner than this is antialiasing, not a line


def profile(path):
    """(width, height, [row]) where a row is a dict of its extent and ink."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    # Per scanline: how many ink pixels, and their mean brightness. One pass,
    # because a second pass over a live screenshot is a different picture.
    lines = []
    for y in range(h):
        n = 0
        tot = 0
        for x in range(w):
            r, g, b = px[x, y]
            if r > INK or g > INK or b > INK:
                n += 1
                tot += r + g + b
        lines.append((n, tot / (3 * n) if n else 0.0))

    rows = []
    start = None
    for y, (n, _) in enumerate(lines + [(0, 0.0)]):
        if n and start is None:
            start = y
        elif not n and start is not None:
            if y - start >= MIN_ROW:
                ink = sum(l[0] for l in lines[start:y])
                # BRIGHTNESS WEIGHTED BY INK, so a row with few bright pixels
                # is not reported as brighter than a row with many: the
                # question is how light the TEXT looks, and a mean over
                # scanlines would be diluted by each row's own padding.
                lum = (sum(l[0] * l[1] for l in lines[start:y]) / ink
                       if ink else 0.0)
                rows.append({"top": start, "bottom": y - 1, "height": y - start,
                             "ink": ink, "lum": round(lum, 1)})
            start = None
    return w, h, rows


def main():
    if len(sys.argv) < 2:
        print("usage: rows.py SHOT.png [--json]", file=sys.stderr)
        return 2
    w, h, rows = profile(sys.argv[1])
    if "--json" in sys.argv[2:]:
        print(json.dumps({"width": w, "height": h, "rows": rows}))
        return 0
    print(f"{w}x{h}, {len(rows)} row(s) of ink")
    prev = None
    for i, r in enumerate(rows):
        gap = "" if prev is None else f"  gap above: {r['top'] - prev}px"
        print(f"  row {i}: y={r['top']}..{r['bottom']} h={r['height']} "
              f"ink={r['ink']} lum={r['lum']}{gap}")
        prev = r["bottom"]
    return 0


if __name__ == "__main__":
    sys.exit(main())
