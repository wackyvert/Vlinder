# Vlinder

A native SwiftUI **Jellyfin viewer for macOS and iOS**, built to
[Fladder](https://github.com/DonutWare/Fladder)'s spec with Tuner's proven
live-TV stream engine. *Vlinder* is Dutch for butterfly — Fladder's natural
next form.

- **Connect**: Quick Connect (preferred) or username/password; saved-account grid, LAN discovery, per-account local URL switching, app lock
- **Home**: hero banner carousel · Continue Watching · Next Up · On Now (live channels) · Continue Listening · Recently added per library
- **Libraries**: sortable poster grids with genre/year/rating/tag filters, pinch poster sizing, endless scrolling
- **Details**: hero/logo headers, resume-aware play, pre-play version/audio/subtitle pickers, chapters, cast, seasons & episodes, special features, external links, similar titles
- **Playback**: AVPlayer with direct play or server HLS transcode, resume, progress reporting, episode auto-advance
- **Live TV**: Xfinity-style guide (frozen channel column, now-line, collapsible relay-lineup groups) + channel list; in-player guide for channel surfing; stream logic ported verbatim from Tuner (`AutoOpenLiveStream` → `TranscodingUrl` → `LiveStreams/Close`)

See [SPEC.md](SPEC.md) for the full Fladder→Vlinder feature map.

## Building

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Vlinder.xcodeproj
```

One multiplatform target, two destinations:

```bash
# macOS
xcodebuild -scheme Vlinder -destination 'platform=macOS' build
# iOS simulator
xcodebuild -scheme Vlinder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The project file is generated — add Swift files under `Sources/` and re-run
`xcodegen generate` (or just build in Xcode; sources are globbed).

## Layout

```
Sources/
  App/        entry point, adaptive navigation (tabs on iOS, sidebar on macOS)
  Core/
    API/      JellyfinClient, DTOs (explicit PascalCase CodingKeys), display helpers
    Session/  Keychain session store, settings, app state
    Images/   cached remote image loading
    Playback/ device profile, PlayerCoordinator (stream lifecycle + reporting)
  Features/   Connect, Home, Library, Detail, Search, LiveTV, Player, Settings
  UI/         cards, rows, shared chrome
```

Transport, Quick Connect, URL handling (reverse-proxy path prefixes,
pre-encoded `TranscodingUrl`), and the live stream flow are ports of Tuner's
known-good implementation — change those with care and test against a real
server, especially live TV.
