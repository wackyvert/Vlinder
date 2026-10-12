# Live TV guide — measured layout contract

Bar: `Design/reference/live-tv-guide.png` (FuboTV EPG grid, 1657×852, dark).
Every number below was measured off that PNG with PIL, cross-checked against a
DOM analysis of Fubo's own grid. Do not re-derive them by eye; do not "improve"
them. If you think a number is wrong, re-measure the PNG and say so.

## Column order (left → right) — this is the whole ask

    [ channel logo, LARGE ]  [ Now Playing thumbnail ]  [ time grid → ]

## Geometry (points, 1x)

| Thing | Value |
|---|---|
| Page background | `#06070A` |
| Content left inset | 79 |
| Logo cell | x 79→230, **w 152**, h 108 |
| Column gap | **12** (everywhere, h and v) |
| Now Playing cell | x 243→434, **w 192**, h 108 — exactly **16:9** |
| Grid origin | x **447** |
| Row cell height | **108**, row pitch **120** |
| First row top | y 111 |
| Header strip | y 51→98 (h 48) |
| Width per minute | **9.4667** (568 px/hour; Fubo measures ~9.45) |
| Program cell width | `duration_min × 9.4667 − 12` |

## Colors

| Thing | Value |
|---|---|
| Logo cell bg | `#161822` |
| Program cell — **airing now** | `#232733` (lighter: this is the live-cell tell) |
| Program cell — future | `#161822` |
| Now-marker | `#FF3A03`, **2 px** wide, spans all rows, above cells |
| "Today" pill bg | `#2D2E34`, radius ~8 |
| Badge pill bg | `#050608` (near-black on the cell), full capsule |
| Cell corner radius | inset **5** on the logo cell, **6** on a program cell |

Measure a corner as the inset at the cell's very top scanline, not by eye.
SwiftUI rasterises one pixel tighter than the reference at the same nominal
radius, so `cellCornerRadius` is **7** to render 6 — do not "correct" it to 6.

## Type & insets

- Program title: 16 from cell left, 16 from cell top, ~19 pt, white, semibold-ish.
- Badge: 17 from cell left, 13 from cell bottom; pill 38×18 for "New"; label ~11 pt.
- Favorite star: 9 pt, inset 14/14 from logo-cell top-left, blue.
- Channel logo: centered both axes in the 152×108 cell; max glyph box ≈ **104×56**
  (measured FOX 102×44, WCCO 48×48). Logos are the largest thing in the row —
  do not shrink them to fit a uniform box. A wide wordmark must be allowed to
  use the full 104; height-binding every asset at 56 is a bug.

### Logos are white glyphs — all of them

Decided by the user, 2026-09-03: *"I'm really not a fan of the sloppiness of the
logos, I like how fubo has them all as white glyphs."*

So the column renders **every** mark as a flat white silhouette taken from the
logo's alpha, and never branches on the asset's own colours for appearance.
This is what makes the reference column read as one object rather than a row of
mismatched vendor assets — and it disposes of two defects at once: dark marks
that vanish into the cell, and assets that ship an opaque white or red
rectangle.

The awkward case is an asset with an **opaque** background (no useful alpha) —
key out its corner colour to recover a mask. Keep the mask's partial alpha;
hard-thresholding chews the glyph edges at this size.

Do **not** solve dark logos by seating them on a light chip. A treatment that
appears on some rows and not others is precisely the sloppiness being rejected.
- Header labels: "Now Playing" at x 244; time labels left-aligned on their tick
  (first at x 448), ~15 pt. Pager chevrons: two ~36 pt circles, right-aligned.
- The "Today ⌄" pill is exactly the logo column's width (152) and sits above it.

## Window origin & clock

Grid starts on the **previous half-hour boundary**, so a little already-aired
time is visible at the left and the leftmost cells never look truncated
mid-word. The reference frame is **origin 9:00 AM, now 9:15 AM** (marker at
x 589). Reproduce exactly that in the fixture.

Vlinder's current `GuideModel.windowStartDate()` uses previous-15-min-minus-15,
which coincides at 9:15 but diverges elsewhere. Move it to the half-hour rule.

## The three empty states — NOT interchangeable

1. **`Upcoming: <title>` + start time** — channel genuinely off-air. No play
   affordance. Not tunable. (Reference row 5, Fresno State at USC.)
2. **`No live content right now`** — feed is up, filler, no EPG record.
   Tunable, play affordance, no record. (Reference bottom row.)
3. **`No information available`** — mid-lane EPG hole. No title styling, no
   actions.

## Synthesized slates — the fallback, and it must not look like one

**Updated 2026-09-03:** the server's EPG was empty because the Schedules Direct
account expired on 2026-08-18. Re-running Jellyfin's `Refresh Guide` after the
renewal repopulated it — 945+ programmes in a 4-hour window, carrying `Primary`
images. So real artwork exists again and the slate is a fallback rather than the
whole column.

It still has to be good. Every one of the three empty states is artwork-less by
definition — an off-air row can never have a programme still — and the slate now
has to sit *beside* photographic cards without reading as a defect. The
reference frame is precisely that mix: four photographic cards and one
synthesized matchup card, and the synthesized one holds its own.

The fixture deliberately carries no programme images, which is what keeps the
fallback path deterministic and testable. Use `--live` for a shot against real
server data.

Historical note, kept because it explains the design: at the time this column
was built the server returned **zero** program images. Fubo composites a
matchup card server-side from pure metadata: two team brand colors as a split
background plus two transparent crests. Ours must do the equivalent
client-side — brand color extracted from the channel logo plus the logo itself,
filling a full 16:9 card. A grey placeholder box is a failure, not a fallback.

Fladder has the same primitive uncommitted at `lib/util/image_colors.dart` and
`lib/screens/shared/media/components/logo_poster.dart` — read them for the
approach, then write it in Swift.

## How to compare

`scripts/guide-shot.sh out.png` builds the app, drives it to the guide on the
pinned fixture, and writes a **1657×852** PNG — the reference's exact frame.
Put your shot next to the reference and judge the same pixels.
