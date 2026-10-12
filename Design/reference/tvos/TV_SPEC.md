# Vlinder on tvOS — standing directions

Bar: the macOS/iOS app itself. Frames: `Design/reference/tvos/mac/*` vs the
tvOS shots beside them. Judge for a viewer ten feet away holding a Siri Remote.

## Owner directions (verbatim, 2026-09-06)

> I specifically want much better library icons and browsing (in ref to
> tv-v0-libraries.png). I hate how the stock Jellyfin ones look and the buttons
> are quite small.

So, for the Libraries screen on the TV:

- **Do not show Jellyfin's stock library cover art.** Those tiles carry the
  library name baked into the picture in Jellyfin's own type; the owner dislikes
  them. Compose our own tile: real artwork from the library's items (a backdrop
  or a fanned set of posters), our own label in our own type, our own gradient.
- **Tiles must be TV-sized.** Round 0's tiles are 232×130 in a 1920-wide frame —
  desk-sized. Fill the width: two or three per row, focus-scaled, with room for
  the label at 10ft.
- **Browsing, not a list.** Focus should feel like the Apple TV app: the focused
  tile lifts and scales, moves with the remote, and opens into the poster grid
  without a detour.

The Mac stays as it is; these are tvOS presentations of the same data.

## Platform facts

- No pointer, hover, keyboard shortcuts, pinch, `.roundedBorder`,
  `.textSelection` on tvOS. Focus is the pointer; everything actionable must be
  focusable and visibly focused.
- `#if os(tvOS)` gates only; macOS and iOS must remain pixel-identical.
- Harness: `scripts/tv-shot.sh out.png 14 -- -OpenSection <home|libraries|liveTV|search|settings>`,
  `scripts/mac-shot.sh` for the bar. Guide autopilot flags work on the TV unchanged.
- `simctl` takes no remote input, so a focus state is photographed by asking
  the screen to focus it: the guide takes `-GuideFocus pill|back|forward|mode|
  logo:R|now:R|cell:R,C` (see `GuideAutopilot`), the way Home takes
  `-HomeFocusPreview 1`. `Design/reference/tvos/tv-v1-guide-focus.png` is the
  six-up sheet of those states.

## Simulator etiquette

Six Apple TV simulators, one per builder — set `TV_UDID` (table in
`scripts/tv-shot.sh`) and never `simctl terminate`/`launch` on a device that is
not yours. Two agents on one device terminate each other's app mid-shot.

## Bar frames when the Mac cannot be captured

macOS screen recording is a TCC grant that can lapse mid-session; when
`mac-shot.sh` fails with "could not create image", use `scripts/ipad-shot.sh`
(iOS build on an iPad simulator, landscape) — same app, same layouts, no
permission needed. Round-0 Mac frames in `mac/` remain valid for the bar; the
Mac code paths are all behind `#if os(tvOS)` gates and did not change.
