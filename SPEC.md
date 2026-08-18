# Vlinder — Fladder-as-spec feature map

Vlinder is a native SwiftUI Jellyfin viewer for **macOS and iOS**, built using
[Fladder](https://github.com/DonutWare/Fladder) as the functional spec and
**Tuner** (`~/ClaudeProjects/Tuner`) as the reference for live TV streaming —
Tuner's stream logic is canonical here; it works markedly better than
Fladder's against this server.

Legend: ✅ shipped · ❌ intentionally out of scope for a "viewer"

## Connect & auth
| Fladder behavior | Vlinder |
|---|---|
| Server URL entry with scheme probing (https→http fallback) | ✅ |
| Quick Connect (initiate → poll → authenticate), auto-refresh expired codes | ✅ ported from Tuner incl. pre-10.9 GET fallback, 401→disabled, 404→expired |
| Username/password (`/Users/AuthenticateByName`) | ✅ |
| Saved-account grid ("Who's watching?"), multi-server/multi-user | ✅ single Keychain item, auto-migrates the v0.1 format |
| Per-account LAN URL with automatic local/remote switching | ✅ probes the local address and swaps the client when it responds |
| UDP LAN discovery (port 7359) | ✅ (macOS; iOS needs Apple's multicast entitlement — degrades to nothing found) |
| App lock passcode | ✅ Keychain-stored, asked at launch |

## Home (dashboard)
| Fladder | Vlinder |
|---|---|
| Hero banner carousel (combined next-up + continue) | ✅ auto-advancing; page-swipe on iOS, arrows on macOS; toggleable |
| Continue Watching / Next Up | ✅ thumb rows |
| Active TV channels row | ✅ "On Now" cards (only when a livetv view exists) |
| Continue Listening (audio resume) | ✅ square-art row |
| Recently added per library | ✅ poster rows |
| Poster-size control (pinch + setting) | ✅ three steps, pinch on library grids |
| Continue Reading | ❌ (needs the book viewer, out of scope) |

## Libraries
| Fladder | Vlinder |
|---|---|
| Views listing, paged grid (prefetch past ~80%) | ✅ 100/page |
| Sorting (name, dateAdded, releaseDate, rating, runtime, random) | ✅ |
| Filters: favorites, unwatched, genres, years, parental ratings, tags | ✅ sheet over `/Items/Filters`, active-count badge |
| Folder/BoxSet/Playlist drill-down | ✅ |
| Multi-select bulk actions, saved filter presets, group-by | ❌ |

## Details
| Fladder | Vlinder |
|---|---|
| Backdrop hero + logo + metadata + overview + genres | ✅ |
| Play/Resume with restart option | ✅ context menu "Play from beginning" |
| Pre-play version / audio / subtitle pickers (MediaStreamHelper) | ✅ chips above the overview; selections flow into PlaybackInfo |
| Favorite / mark-watched, cast row | ✅ |
| Chapters row (thumbnails, tap seeks) | ✅ plays from chapter position |
| Series: season picker + episode list, next-up-aware play target | ✅ |
| Special features row | ✅ movies & episodes |
| External links (IMDb, TMDb, …) | ✅ chips |
| Similar / "More Like This" | ✅ |
| Media info summary (resolution/codec/audio/sub count) | ✅ |
| Metadata editing, identify, refresh | ❌ (admin features) |

## Playback (VOD)
| Fladder | Vlinder |
|---|---|
| PlaybackInfo with device profile → direct play vs HLS transcode | ✅ AVPlayer-native profile |
| Resume (server-side offset for transcode, client seek for direct) | ✅ |
| Start/progress/stopped reporting + transcode cleanup | ✅ every 10 s |
| Next-episode auto-advance + prev/next controls | ✅ |
| Subtitles via HLS-segmented VTT (native AVPlayer menu) | ✅ |
| Media segments skip, trickplay scrubbing, mpv backend, hotkey editor | ❌ (AVFoundation-native player) |

## Live TV — **Tuner logic, verbatim**
| Behavior | Vlinder |
|---|---|
| `AutoOpenLiveStream` PlaybackInfo → prefer `TranscodingUrl` → `stream.ts` fallback | ✅ `DeviceProfile.live` is byte-for-byte Tuner (do not extend — extra profile entries caused CoreMedia -12705) |
| `POST /LiveStreams/Close` on teardown + progress keepalive | ✅ |
| **Xfinity-style guide**: frozen channel column, timeline header, now-line, "Now" jump | ✅ 16-hour window from the 15-min boundary −15 min |
| Bulk program paging (800/page, incremental apply, 45-min staleness, race guard) | ✅ ported from the Fladder fork's provider |
| **Lineup-URL channel grouping** (M3U / lineup JSON relay) | ✅ parser + cached loader ported verbatim from Tuner/Fladder — same relay contract |
| Collapsible groups (persisted), "Other Channels" bucket, search auto-expand | ✅ |
| Program cells: airing highlight, genre color bars, past dimming, future-program switch dialog | ✅ |
| Channel list alternative view (favorites first, now-playing progress) | ✅ toolbar toggle |
| In-player guide overlay for channel surfing | ✅ sheet from the live player |

## Search
Global `/Users/{id}/Items?searchTerm` (400 ms debounce), grouped by
Movies/Series/Episodes/Collections/People/Channels — ✅.

## Settings
Account info + LAN override + sign out, saved accounts (switch/add/remove),
theme (system/light/dark), poster size, home banner toggle, streaming quality,
Live TV (channel numbers, lineup URL + refresh with group count), app lock,
about — ✅. Subtitle appearance editor, remappable hotkeys, downloads — ❌.

## Out of scope (viewer)
Seerr/Overseerr, sync/offline downloads, book & photo viewers, music-first UX,
server admin control panel, metadata editing, mpv/libass playback backends.

## Verified against real infrastructure (2026-08-18)
Jellyfin 10.10.7 → 10.11.11 (jf.torgerson.cc), Northstar relay lineup
(7 groups / 82 channels): Quick Connect, home rows, grouped guide with live
program data, live channel tuning (transcoded MPEG-2), VOD resume, session
migration.
