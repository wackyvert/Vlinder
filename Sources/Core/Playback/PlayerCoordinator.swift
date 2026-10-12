import AVFoundation
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Owns the AVPlayer, stream lifecycle, and server reporting for both VOD and
/// live TV. Core patterns ported from Tuner's PlayerViewModel:
/// - a monotonic `generation` guards every async completion so a superseded
///   tune can't clobber a newer one (a superseded stream is closed immediately)
/// - state stays "loading" until AVPlayerItem reports readyToPlay; failures have
///   no auto-retry by design
/// - teardown reporting runs in a detached Task that outlives the coordinator's UI
@MainActor
@Observable
final class PlayerCoordinator {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var player: AVPlayer?
    private(set) var title: String = ""
    private(set) var subtitle: String?
    private(set) var isLive = false
    var isPresented = false
    /// Artwork for the tuning/loading slate: the channel's mark or programme
    /// picture for live, the item's own primary/backdrop for VOD. Purely
    /// presentational — set alongside the title, never read by stream logic.
    private(set) var tuningArtwork: TuningArtwork?
    /// Ticks the server skipped before player-time zero on the current stream
    /// (a transcode resume). Zero for direct play and live. Mirrors
    /// `ActiveStream.startOffsetTicks` for the UI, which cannot see `active`.
    private(set) var playerLocalZeroTicks: Int64 = 0
    /// The VOD item playing now, so a transport can replay it from the start.
    private(set) var currentItem: BaseItem?

    struct TuningArtwork: Equatable {
        /// Channel logo (live) or poster (VOD); shown as the mark.
        var mark: URL?
        /// Programme/backdrop picture behind the mark; nil falls back to mark only.
        var backdrop: URL?
    }

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var settings = AppSettings()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var active: ActiveStream?
    @ObservationIgnored private var queue: [BaseItem] = []
    @ObservationIgnored private var queueIndex: Int = 0
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?

    private struct ActiveStream {
        var itemId: String
        var stream: JellyfinClient.ResolvedStream
        /// Ticks the server skipped for us (transcode resume); player time 0 == this offset.
        var startOffsetTicks: Int64
    }

    init() {
        #if DEBUG
        PlaybackAutopilot.start(on: self)
        #endif
    }

    // MARK: - Entry points

    /// The item currently loaded (channel id during live playback).
    private(set) var currentItemId: String?

    /// Play a VOD item, optionally within a queue (episode auto-advance).
    /// `startTicks` overrides the resume position (chapter jumps).
    func play(
        item: BaseItem,
        queue: [BaseItem] = [],
        fromBeginning: Bool = false,
        startTicks: Int64? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        mediaSourceId: String? = nil,
        client: JellyfinClient,
        settings: AppSettings
    ) {
        self.client = client
        self.settings = settings
        if !queue.isEmpty, let index = queue.firstIndex(where: { $0.id == item.id }) {
            self.queue = queue
            self.queueIndex = index
        } else {
            self.queue = []
            self.queueIndex = 0
        }
        let resumeTicks = startTicks ?? (fromBeginning ? nil : item.resumeTicks)
        currentItemId = item.id
        currentItem = item
        tune(title: item.displayTitle, subtitle: item.posterSubtitle, live: false,
             artwork: Self.artwork(forItem: item, client: client)) { [weak self] in
            guard let self else { throw JellyfinError.noMediaSource }
            let stream = try await client.startVideoStream(
                itemId: item.id,
                startTimeTicks: resumeTicks,
                mediaSourceId: mediaSourceId,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex)
            let offset: Int64 = stream.playMethod == "Transcode" ? (resumeTicks ?? 0) : 0
            let seekTicks: Int64? = stream.playMethod == "Transcode" ? nil : resumeTicks
            return (ActiveStream(itemId: item.id, stream: stream, startOffsetTicks: offset), seekTicks)
        }
    }

    /// Play a live TV channel — resolution goes through Tuner's proven stream logic.
    func playChannel(_ channel: BaseItem, client: JellyfinClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
        self.queue = []
        self.queueIndex = 0
        currentItemId = channel.id
        currentItem = nil
        let subtitleText = channel.currentProgram?.value.name
        tune(title: channel.displayTitle, subtitle: subtitleText, live: true,
             artwork: Self.artwork(forChannel: channel, client: client)) {
            let stream = try await client.startLiveStream(channelId: channel.id)
            return (ActiveStream(itemId: channel.id, stream: stream, startOffsetTicks: 0), nil)
        }
    }

    /// True when the stream started mid-way at a point the player cannot
    /// scrub before (transcode resume: the server skipped the head and AVKit's
    /// timeline begins at the resume point). The transport offers "From
    /// Beginning" in that case rather than pretending the head is reachable.
    var canRestartFromBeginning: Bool {
        !isLive && playerLocalZeroTicks > 0 && currentItem != nil
    }

    /// Replay the current VOD item from its start, same queue, resume ignored.
    func restartFromBeginning() {
        guard let client, let item = currentItem else { return }
        let savedQueue = queue
        play(item: item, queue: savedQueue, fromBeginning: true, client: client, settings: settings)
    }

    var hasNextInQueue: Bool {
        !queue.isEmpty && queueIndex + 1 < queue.count
    }

    var hasPreviousInQueue: Bool {
        !queue.isEmpty && queueIndex > 0
    }

    func playNextInQueue() {
        guard hasNextInQueue, let client else { return }
        let next = queue[queueIndex + 1]
        let savedQueue = queue
        play(item: next, queue: savedQueue, fromBeginning: true, client: client, settings: settings)
    }

    func playPreviousInQueue() {
        guard hasPreviousInQueue, let client else { return }
        let previous = queue[queueIndex - 1]
        let savedQueue = queue
        play(item: previous, queue: savedQueue, fromBeginning: true, client: client, settings: settings)
    }

    // MARK: - Tuning

    private func tune(
        title: String,
        subtitle: String?,
        live: Bool,
        artwork: TuningArtwork? = nil,
        resolve: @escaping () async throws -> (ActiveStream, Int64?)
    ) {
        generation += 1
        let thisGeneration = generation

        // Tear down whatever is playing (reports stopped + frees the tuner server-side).
        teardownCurrent(finalTicks: currentPositionTicks())

        self.title = title
        self.subtitle = subtitle
        self.isLive = live
        self.tuningArtwork = artwork
        self.playerLocalZeroTicks = 0
        self.state = .loading
        self.isPresented = true
        configureAudioSession()

        Task { [weak self] in
            do {
                let (stream, seekTicks) = try await resolve()
                guard let self, self.generation == thisGeneration else {
                    // Superseded while resolving: free the stream we just opened.
                    if let client = self?.client {
                        Self.closeStream(stream, client: client)
                    }
                    return
                }
                self.begin(stream: stream, seekTicks: seekTicks)
            } catch {
                guard let self, self.generation == thisGeneration else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func begin(stream: ActiveStream, seekTicks: Int64?) {
        active = stream
        playerLocalZeroTicks = stream.startOffsetTicks
        let asset = AVURLAsset(url: stream.stream.url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // macOS: external playback engaging (e.g. an AirPlay audio route)
        // replaces local video with a placeholder glyph; keep rendering local.
        // iOS keeps it on for the real AirPlay button in the player UI.
        #if os(macOS)
        player.allowsExternalPlayback = false
        #else
        player.allowsExternalPlayback = true
        #endif
        self.player = player

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.state == .loading else { return }
                    if let seekTicks {
                        let seconds = Double(seekTicks) / 10_000_000
                        self.player?.seek(
                            to: CMTime(seconds: seconds, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                    }
                    self.player?.play()
                    self.state = .playing
                    self.reportStart()
                    self.startProgressLoop()
                    #if DEBUG
                    let size = item.presentationSize
                    let tracks = item.tracks.map { track in
                        "\(track.assetTrack?.mediaType.rawValue ?? "?"):\(track.isEnabled ? "on" : "off")"
                    }.joined(separator: ",")
                    NSLog("[Vlinder] ready presentation=%.0fx%.0f tracks=%@", size.width, size.height, tracks)
                    #endif
                case .failed:
                    self.handlePlaybackFailure(error: item.error, item: item)
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let failedItem = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(error: error, item: failedItem)
            }
        }
    }

    /// A dead player must not keep server resources allocated: report stopped
    /// and close the live stream immediately, then show the error. Dismissing
    /// later is a no-op on the already-released stream.
    private func handlePlaybackFailure(error: Error?, item: AVPlayerItem?) {
        guard active != nil else {
            if case .failed = state {} else {
                state = .failed(Self.describePlaybackError(error, item: item))
            }
            return
        }
        let message = Self.describePlaybackError(error, item: item)
        reportTask?.cancel()
        reportTask = nil
        player?.pause()
        releaseServerResources(finalTicks: currentPositionTicks())
        state = .failed(message)
        #if DEBUG
        print("[Vlinder] playback failure: \(message)")
        #endif
    }

    /// "Operation stopped" alone is useless; include the redacted NSError
    /// domain/code and the last AVPlayerItem error-log event.
    private static func describePlaybackError(_ error: Error?, item: AVPlayerItem?) -> String {
        var parts: [String] = []
        if let error {
            let nsError = error as NSError
            parts.append("\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]")
        } else {
            parts.append("Playback failed.")
        }
        if let event = item?.errorLog()?.events.last {
            var detail = "\(event.errorDomain) \(event.errorStatusCode)"
            if let comment = event.errorComment, !comment.isEmpty {
                detail += " — \(comment)"
            }
            parts.append(JellyfinClient.redactingAPIKey(detail))
        }
        return parts.joined(separator: "\n")
    }

    private func handlePlaybackEnded() {
        if !isLive, hasNextInQueue {
            playNextInQueue()
        } else {
            dismiss()
        }
    }

    // MARK: - Reporting

    private func currentPositionTicks() -> Int64 {
        guard let player else { return active?.startOffsetTicks ?? 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return active?.startOffsetTicks ?? 0 }
        return (active?.startOffsetTicks ?? 0) + Int64(seconds * 10_000_000)
    }

    private func reportStart() {
        guard let client, let active else { return }
        let body = PlaybackStartBody(
            itemId: active.itemId,
            mediaSourceId: active.stream.mediaSourceId,
            playSessionId: active.stream.playSessionId,
            liveStreamId: active.stream.liveStreamId,
            canSeek: !isLive,
            playMethod: active.stream.playMethod,
            positionTicks: currentPositionTicks())
        Task.detached { await client.reportPlaybackStart(body) }
    }

    private func startProgressLoop() {
        reportTask?.cancel()
        let interval = max(settings.progressReportInterval, 3)
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.reportProgress()
            }
        }
    }

    private func reportProgress() async {
        guard let client, let active, let player else { return }
        let body = PlaybackProgressBody(
            itemId: active.itemId,
            mediaSourceId: active.stream.mediaSourceId,
            playSessionId: active.stream.playSessionId,
            liveStreamId: active.stream.liveStreamId,
            positionTicks: currentPositionTicks(),
            isPaused: player.timeControlStatus != .playing,
            playMethod: active.stream.playMethod)
        await client.reportPlaybackProgress(body)
    }

    // MARK: - Teardown

    /// Stop playback and close the overlay.
    func dismiss() {
        generation += 1
        teardownCurrent(finalTicks: currentPositionTicks())
        isPresented = false
        state = .idle
        title = ""
        subtitle = nil
        currentItemId = nil
        currentItem = nil
        tuningArtwork = nil
        playerLocalZeroTicks = 0
    }

    // MARK: - Tuning artwork

    private static func artwork(forChannel channel: BaseItem, client: JellyfinClient) -> TuningArtwork {
        let program = channel.currentProgram?.value
        let programTags = program?.imageTags ?? [:]
        let backdrop: URL? = program.flatMap { program in
            if let tag = programTags["Thumb"] {
                return client.imageURL(itemId: program.id, type: .thumb, tag: tag, maxWidth: 1280)
            }
            if let tag = programTags["Primary"] {
                return client.imageURL(itemId: program.id, type: .primary, tag: tag, maxWidth: 1280)
            }
            return nil
        }
        return TuningArtwork(
            mark: client.imageURL(itemId: channel.id, type: .primary, tag: channel.imageTags?["Primary"], maxWidth: 800),
            backdrop: backdrop)
    }

    private static func artwork(forItem item: BaseItem, client: JellyfinClient) -> TuningArtwork {
        var backdrop: URL?
        if let tag = item.backdropImageTags?.first {
            backdrop = client.imageURL(itemId: item.id, type: .backdrop, tag: tag, maxWidth: 1920)
        } else if let parentId = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            backdrop = client.imageURL(itemId: parentId, type: .backdrop, tag: tag, maxWidth: 1920)
        }
        var mark = client.imageURL(itemId: item.id, type: .primary, tag: item.imageTags?["Primary"], maxWidth: 600)
        if mark == nil, let seriesId = item.seriesId {
            mark = client.imageURL(itemId: seriesId, type: .primary, tag: item.seriesPrimaryImageTag, maxWidth: 600)
        }
        return TuningArtwork(mark: mark, backdrop: backdrop)
    }

    private func teardownCurrent(finalTicks: Int64) {
        reportTask?.cancel()
        reportTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        player?.pause()
        player = nil
        releaseServerResources(finalTicks: finalTicks)
    }

    /// Reports stopped and frees the tuner/encoder server-side. Safe to call
    /// more than once — the first call consumes `active`.
    private func releaseServerResources(finalTicks: Int64) {
        guard let client, let active else { return }
        self.active = nil
        let stopBody = PlaybackStopBody(
            itemId: active.itemId,
            mediaSourceId: active.stream.mediaSourceId,
            playSessionId: active.stream.playSessionId,
            liveStreamId: active.stream.liveStreamId,
            positionTicks: finalTicks)
        let stream = active.stream
        // Deliberately outlives this object (Tuner pattern).
        Task.detached {
            await client.reportPlaybackStopped(stopBody)
            Self.closeStream(ActiveStream(itemId: active.itemId, stream: stream, startOffsetTicks: 0), client: client)
        }
    }

    private nonisolated static func closeStream(_ stream: ActiveStream, client: JellyfinClient) {
        Task.detached {
            if let liveStreamId = stream.stream.liveStreamId {
                await client.closeLiveStream(liveStreamId: liveStreamId)
            }
            if stream.stream.playMethod == "Transcode" {
                await client.stopActiveEncodings(playSessionId: stream.stream.playSessionId)
            }
        }
    }

    /// tvOS launches apps in the ambient category, which mutes video under
    /// the system's own audio and ignores the mute switch semantics a player
    /// wants — same fix as iOS.
    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

#if DEBUG
/// Launch-argument autopilot so a harness can drop straight into the player on
/// either platform without driving the UI:
///
///   -PlayChannel <number|id>  tune a live channel by its guide number ("4") or
///                             item id; ids go stale whenever the tuner
///                             refreshes, numbers do not
///   -PlayItem <id|resume>     play a library item honouring its resume
///                             position; "resume" takes the first entry of
///                             Continue Watching so the resume path is testable
///                             without knowing an id
///   -PlayShowGuide 1          (tvOS) open the in-player guide once the stream is up
///
/// Builds its own client from the stored session rather than waiting on
/// AppState, so it lives entirely in the playback layer and needs nothing
/// wired through RootView.
enum PlaybackAutopilot {
    private static var defaults: UserDefaults { .standard }

    static var channelId: String? { defaults.string(forKey: "PlayChannel") }
    static var itemId: String? { defaults.string(forKey: "PlayItem") }
    static var showsGuide: Bool { defaults.object(forKey: "PlayShowGuide") != nil }
    static var isActive: Bool { channelId != nil || itemId != nil }

    @MainActor
    static func start(on coordinator: PlayerCoordinator) {
        guard isActive else { return }
        Task { @MainActor in
            // Let RootView settle into the signed-in phase first, otherwise the
            // overlay would appear over the launch spinner and be torn down
            // with it.
            try? await Task.sleep(for: .seconds(1.5))
            let stored = SessionStore.load()
            guard let session = stored.accounts.first(where: { $0.id == stored.activeId }) ?? stored.accounts.first else {
                log("no stored session")
                return
            }
            let client = JellyfinClient(
                serverURL: session.serverURL,
                deviceId: session.deviceId,
                accessToken: session.accessToken,
                userId: session.userId)
            let settings = AppSettings.load()
            do {
                if let channelId {
                    let channel = try await resolveChannel(channelId, client: client)
                    coordinator.playChannel(channel, client: client, settings: settings)
                } else if let itemId {
                    let item = try await resolveItem(itemId, client: client)
                    let queue = await episodeQueue(for: item, client: client)
                    coordinator.play(item: item, queue: queue, client: client, settings: settings)
                }
            } catch {
                log("\(error)")
            }
        }
    }

    private static func resolveChannel(_ key: String, client: JellyfinClient) async throws -> BaseItem {
        if key.count > 8, let channel = try? await client.item(id: key) {
            return channel
        }
        let channels = try await client.liveTvChannels()
        guard let match = channels.first(where: { $0.id == key || $0.channelNumber == key || $0.number == key })
                ?? channels.first else {
            throw JellyfinError.noMediaSource
        }
        log("channel \(key) -> \(match.displayTitle) [\(match.id)]")
        return match
    }

    private static func resolveItem(_ key: String, client: JellyfinClient) async throws -> BaseItem {
        if key == "resume" {
            guard let item = try await client.resumeItems(limit: 1).first else {
                throw JellyfinError.noMediaSource
            }
            log("resume -> \(item.displayTitle) [\(item.id)] at \(item.resumeTicks ?? 0) ticks")
            return item
        }
        return try await client.item(id: key)
    }

    /// The detail screens hand an episode its season as the queue, which is
    /// what lights up next/previous — the autopilot does the same so those
    /// actions are on screen to be checked.
    private static func episodeQueue(for item: BaseItem, client: JellyfinClient) async -> [BaseItem] {
        guard item.type == .episode, let seriesId = item.seriesId else { return [] }
        return (try? await client.episodes(seriesId: seriesId, seasonId: item.seasonId)) ?? []
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("play-autopilot: \(message)\n".utf8))
    }
}
#endif
