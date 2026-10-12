#!/usr/bin/env python3
"""Measure a guide screenshot against the reference, numerically.

    scripts/guide-diff.py Design/reference/shots/v1.png [reference.png]

Taste is the critic's job. This is the half that does not drift between rounds:
it reports the geometry each image actually has — background, row pitch, cell
height, the three column widths, the now-marker — so a verdict can cite a
number instead of a feeling.

Deliberately does no thresholding against a guessed background: it takes the
modal colour of the image as the page, and votes across many scanlines, because
a single mis-sampled row silently turns every number into fiction.
"""
import sys
from collections import Counter

from PIL import Image

REFERENCE = "Design/reference/live-tv-guide.png"


def page_colour(im, step=3):
    """The page behind the cells: the darkest of the image's common colours.

    Not simply the most common one — cells cover more area than the page does,
    so the plain mode picks a cell and every later measurement then reads the
    gaps as if they were cells.
    """
    px = im.load()
    counts = Counter()
    for y in range(0, im.height, step):
        for x in range(0, im.width, step):
            counts[px[x, y]] += 1
    # Darkest of the colours that actually cover ground. Without the area
    # floor this picks the badge capsule (#050608), which is darker than the
    # page but covers a few hundred pixels.
    total = sum(counts.values())
    common = [c for c, n in counts.most_common(8) if n >= total * 0.04]
    if not common:
        common = [c for c, _ in counts.most_common(3)]
    return min(common, key=lambda c: c[0] + c[1] + c[2])


def near(a, b, tol=6):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def runs(values, keep, floor=8):
    out, start = [], None
    for i, v in enumerate(values):
        if keep(v):
            if start is None:
                start = i
        elif start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(values) - 1))
    return [(a, b) for a, b in out if b - a + 1 >= floor]


def measure(path):
    im = Image.open(path).convert("RGB")
    px = im.load()
    w, h = im.size
    page = page_colour(im)

    # Vote for the row rhythm across many columns, ignoring the header band.
    heights, pitches, first_tops = Counter(), Counter(), Counter()
    for x in range(20, w - 20, 17):
        blocks = [
            (a, b) for a, b in runs([px[x, y] for y in range(h)], lambda c: not near(c, page))
            if a > 60
        ]
        if len(blocks) < 3:
            continue
        first_tops[blocks[0][0]] += 1
        for a, b in blocks:
            heights[b - a + 1] += 1
        for (a, _), (a2, _) in zip(blocks, blocks[1:]):
            if a2 - a > 40:
                pitches[a2 - a] += 1

    cell_h = heights.most_common(1)[0][0] if heights else None
    pitch = pitches.most_common(1)[0][0] if pitches else None
    top = first_tops.most_common(1)[0][0] if first_tops else h // 4

    # Columns, sampled near the bottom of the first cell row rather than its
    # middle: logos are centred, and a dark logo on a dark cell reads as page
    # colour, which splits one column into three.
    y = top + (cell_h or 100) - 8
    cols = [(a, b - a + 1) for a, b in runs(
        [px[x, y] for x in range(w)], lambda c: not near(c, page), floor=20)]

    # Now-marker: the column that is red down the whole grid, not merely red at
    # one scanline — programme artwork contains plenty of red pixels.
    red_per_x = []
    for x in range(w):
        count = sum(
            1 for yy in range(top, h, 4)
            if px[x, yy][0] > 130 and px[x, yy][0] - px[x, yy][1] > 80)
        red_per_x.append(count)
    span = len(range(top, h, 4))
    marker = [x for x, count in enumerate(red_per_x) if count > span * 0.6]

    return {
        "size": (w, h),
        "page_bg": page,
        "row_pitch": pitch,
        "cell_height": cell_h,
        "first_row_top": top,
        "columns": cols[:5],
        "marker_x": marker[0] if marker else None,
        "marker_w": len(marker),
        "sample_y": y,
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    mine = measure(sys.argv[1])
    theirs = measure(sys.argv[2] if len(sys.argv) > 2 else REFERENCE)

    print(f"{'':16} {'OURS':<26} REFERENCE")
    for key in ("size", "page_bg", "row_pitch", "cell_height",
                "first_row_top", "marker_x", "marker_w"):
        a, b = mine[key], theirs[key]
        same = a == b or (
            isinstance(a, tuple) and isinstance(b, tuple) and near(a, b))
        print(f"{key:16} {str(a):<26} {b}{'' if same else '   <-- differs'}")

    print(f"\ncolumns as (x, width), first cell row"
          f" — ours y={mine['sample_y']}, ref y={theirs['sample_y']}")
    print(f"  ours: {mine['columns']}")
    print(f"  ref : {theirs['columns']}")
    print("\nExpected order: logo cell ~152 wide, Now Playing ~192, then grid cells.")
    print("Reference truth: pitch 120, cell 108, gap 12, marker 2px #FF3A03.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
