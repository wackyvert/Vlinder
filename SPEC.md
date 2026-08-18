# Vlinder — Fladder-as-spec feature map

Vlinder is a native SwiftUI Jellyfin viewer for **macOS and iOS**, built using
[Fladder](https://github.com/DonutWare/Fladder) as the functional spec and
**Tuner** (`~/ClaudeProjects/Tuner`) as the reference for live TV streaming —
Tuner's stream logic is canonical here; it works markedly better than
Fladder's against this server.

Legend: ✅ shipped in v0.1 · 🔜 planned · ❌ out of scope for a "viewer"

## Connect & auth
| Fladder behavior | Vlinder |
|---|---|
| Server URL entry with scheme probing (https→http fallback) | ✅ `ConnectView` / `JellyfinClient.normalizeServerInput` |
| Quick Connect (initiate → poll → authenticate), auto-refresh expired codes | ✅ ported from Tuner incl. pre-10.9 GET fallback, 401→disabled, 404→expired |
| Username/password (`/Users/AuthenticateByName`) | ✅ |
| Session persistence | ✅ single Keychain item (`dev.jake.vlinder.session`), UserDefaults fallback for unsigned dev builds |
| Multi-server / multi-user account grid, per-account LAN URL, lock screen | 🔜 single active session in v0.1 |
| UDP LAN discovery (port 7359) | 🔜 |

## Home (dashboard)
| Fladder | Vlinder |
|---|---|
| Continue Watching (`/Users/{id}/Items/Resume`) | ✅ thumb row |
| Next Up (`/Shows/NextUp`) | ✅ thumb row |
| Active TV channels row | ✅ "On Now" channel cards (only when a livetv view exists) |
| Recently added per library (`/Items/Latest` per view) | ✅ poster rows |
| Hero banner carousel, continue listening/reading, poster-size pinch | 🔜 |

## Libraries
| Fladder | Vlinder |
|---|---|
| Views listing (`/Users/{id}/Views`) | ✅ grid of library cards |
| Paged item grid (offset/limit, load past 65%) | ✅ 100/page, prefetch near end |
| Sorting (name, dateAdded, releaseDate, rating, runtime, random) | ✅ |
| Filters: favorites, unplayed | ✅ (genres/years/studios/tags 🔜) |
| Folder/BoxSet/Playlist drill-down | ✅ non-recursive child listing |
| Multi-select bulk actions, saved filter presets, group-by | ❌ |

## Details
| Fladder | Vlinder |
|---|---|
| Backdrop hero + logo + metadata + overview + genres | ✅ `DetailHeader` |
| Play/Resume with long-press restart | ✅ (context menu "Play from beginning") |
| Favorite / mark-watched toggles | ✅ |
| Cast & crew row | ✅ |
| Series: season picker + episode list w/ stills, next-up-aware play target | ✅ |
| Episode: sibling episodes row | ✅ |
| Similar / "More Like This" (`/Items/{id}/Similar`) | ✅ movies & series |
| Media info (resolution/codec/audio) | ✅ one-line summary |
| Pre-play version/audio/subtitle pickers | 🔜 (plumbing exists in `startVideoStream`) |
| Chapters row, special features, external links, metadata editing | 🔜/❌ |

## Playback (VOD)
| Fladder | Vlinder |
|---|---|
| PlaybackInfo with device profile → direct play vs HLS transcode | ✅ AVPlayer-native profile (mp4/mov/ts + h264/hevc direct; HLS/ts transcode) |
| Resume (server-side offset for transcode, client seek for direct) | ✅ offset-aware position reporting |
| Start/progress/stopped reporting + transcode cleanup | ✅ every 10 s + `DELETE /Videos/ActiveEncodings` |
| Next-episode auto-advance in a season queue | ✅ on end-of-item; prev/next buttons in overlay |
| Subtitle delivery | ✅ HLS-segmented VTT via subtitle profile (AVPlayer native menu) |
| Smart outro-based next prompt, media segments skip, trickplay, mpv backend | ❌ (AVFoundation only) |

## Live TV — **Tuner logic, verbatim**
| Behavior | Vlinder |
|---|---|
| `POST /Items/{ch}/PlaybackInfo` with `AutoOpenLiveStream` | ✅ one round trip opens the tuner |
| Prefer server `TranscodingUrl` (HLS), else `stream.ts` fallback | ✅ |
| `POST /LiveStreams/Close` on teardown (frees tuner for channel hops) | ✅ + progress keepalive every 10 s (Tuner lacked this) |
| Channel list sorted number→name, favorites first | ✅ with now-playing + progress |
| Search channels/programs | ✅ |
| Guide grid (Xfinity-style), lineup-URL channel grouping (M3U/JSON relay) | 🔜 — port `LineupParser`/`LineupLoader` from Tuner (pure Foundation) |

## Search
Global `/Users/{id}/Items?searchTerm` (400 ms debounce), grouped by
Movies/Series/Episodes/Collections/People/Channels — ✅.

## Settings
Account info + sign out, streaming quality ceiling, Live TV channel numbers —
✅. Theme, subtitle appearance, hotkeys, downloads — 🔜/❌.

## Out of scope (viewer)
Seerr/Overseerr, sync/offline downloads, book & photo viewers, music-first UX,
server admin control panel, metadata editing.
