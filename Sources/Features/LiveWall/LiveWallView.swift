import QuartzCore
import SwiftUI

/// SwiftUI composition of the Live TV Atrium: hosts the SceneKit wall, mirrors
/// the guide's grouped channels into it, and hands a tuned channel to the same
/// PlayerCoordinator the flat guide uses.
///
/// The wall carries its own chrome — every card says what it is — so there is
/// no selection panel over it. The only thing SwiftUI puts on top is the state
/// the wall cannot show: that the guide is still loading, or would not.
struct LiveWallView: View {
    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @Environment(GuideModel.self) private var guide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var controller = LiveWallSceneController()
    @State private var onNow = LiveWallNowModel()
    @State private var syncedSignature: String = ""
    @State private var selected: LiveWallCard?
    #if DEBUG
    @State private var autopilotRan = false
    #endif

    private var bands: [LiveWallBand] { LiveWallArrangement.bands(from: guide, now: onNow) }

    var body: some View {
        LiveWallRepresentable(controller: controller)
            .accessibilityRepresentation { accessibleFallback }
            .overlay { status }
            .background(.black)
            .onChange(of: signature, initial: true) {
                wireController()
                syncWall()
            }
            .onChange(of: colorScheme) { controller.setAppearance(dark: colorScheme == .dark) }
            .onChange(of: reduceMotion) { controller.reduceMotion = reduceMotion }
            .task { await refresh() }
            #if DEBUG
            .task { await watchdog() }
            #endif
    }

    /// Changes worth restanding the wall for: which channels, in which groups,
    /// and which programme is on each — not the second-by-second progress.
    private var signature: String {
        let bands = bands
        return bands.map { band in
            "\(band.name)#\(band.cards.map { "\($0.id):\($0.program?.id ?? "")" }.joined(separator: ","))"
        }.joined(separator: "|")
    }

    // MARK: - Wiring

    private func wireController() {
        controller.reduceMotion = reduceMotion
        controller.setAppearance(dark: colorScheme == .dark)
        controller.setArtworkSource(.init(
            still: { card, maxWidth in
                app.client?.imageURL(card.artwork, maxWidth: maxWidth)
            }))
        controller.onSelectionChange = { selected = $0 }
        controller.onPlay = { card in
            guard let client = app.client else { return }
            player.playChannel(card.channel, client: client, settings: app.settings)
        }
    }

    private func syncWall() {
        guard signature != syncedSignature else { return }
        syncedSignature = signature
        controller.update(bands: bands)
        controller.refreshFaces()
        #if DEBUG
        runAutopilotIfNeeded()
        #endif
    }

    private func refresh() async {
        guard let client = app.client else { return }
        // The channels first — nothing can be drawn without them — then what is
        // on them, which the wall fetches for itself.
        await guide.ensureFresh(client: client, settings: app.settings)
        await onNow.ensureFresh(client: client)
    }

    // MARK: - State the wall cannot show

    @ViewBuilder
    private var status: some View {
        switch guide.status {
        case .loadingChannels, .idle:
            CenteredProgressView()
        case .error(let message) where guide.channels.isEmpty:
            ErrorRetryView(message: message) {
                Task {
                    guard let client = app.client else { return }
                    await guide.fetch(client: client, settings: app.settings)
                }
            }
        case .loaded where guide.channels.isEmpty:
            ContentUnavailableView(
                "No channels", systemImage: "tv",
                description: Text("This server has no Live TV channels."))
        default:
            EmptyView()
        }
    }

    /// VoiceOver cannot look at a wall, so it gets the same channels as a list.
    private var accessibleFallback: some View {
        VStack(alignment: .leading) {
            ForEach(bands) { band in
                Text(band.name)
                ForEach(band.cards) { card in
                    Button(accessibilityLabel(for: card)) {
                        guard let client = app.client else { return }
                        player.playChannel(card.channel, client: client, settings: app.settings)
                    }
                }
            }
        }
    }

    private func accessibilityLabel(for card: LiveWallCard) -> String {
        var parts: [String] = []
        if !card.channelNumber.isEmpty { parts.append("Channel \(card.channelNumber)") }
        parts.append(card.channelName)
        parts.append("now playing \(card.title)")
        if let start = card.startLabel, let end = card.endLabel {
            parts.append("\(start) to \(end)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Autopilot

    #if DEBUG
    /// Says out loud what the wall is waiting for, and refuses to hang: a
    /// screenshot harness that sits there forever is worse than one that fails.
    private func watchdog() async {
        guard LiveWallAutopilot.isActive else { return }
        let deadline = Date().addingTimeInterval(LiveWallAutopilot.deadlineSeconds)
        var attempts = 0
        while Date() < deadline {
            if autopilotRan { return }
            print("wall-wait: client=\(app.client != nil) status=\(guide.status) "
                + "channels=\(guide.channels.count) onNow=\(onNow.programs.count) "
                + "bands=\(bands.count) err=\(onNow.errorMessage ?? "-")")

            // SwiftUI owns the lifetime of a `.task`, and under the autopilot
            // the view is restood often enough that the guide's own fetch can
            // be cancelled out from under it. Drive it from a task nothing is
            // going to tear down.
            //
            // A cancelled *programme* fetch is worse than a cancelled channel
            // fetch, because the guide still calls itself loaded afterwards —
            // so a wall of channels with nothing on them counts as a failure
            // here and gets refetched too.
            if needsRefetch, attempts < 3, let client = app.client {
                attempts += 1
                let settings = app.settings
                let guide = guide
                let onNow = onNow
                Task.detached { @MainActor in
                    await guide.fetch(client: client, settings: settings)
                    await onNow.load(client: client)
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        print("wall-wait: gave up — client=\(app.client != nil) status=\(guide.status) "
            + "channels=\(guide.channels.count) programmes=\(guide.programsByChannel.count) "
            + "bands=\(bands.count)")
        LiveWallAutopilot.quitIfAsked()
    }

    /// The guide reports itself loaded even when only the channel list
    /// arrived, so "loaded with no programmes" has to be treated as unfinished.
    private var needsRefetch: Bool {
        if case .error = guide.status { return true }
        return guide.status == .loaded && !guide.channels.isEmpty
            && guide.programsByChannel.isEmpty && onNow.programs.isEmpty
    }

    private func runAutopilotIfNeeded() {
        // A wall of channels with nothing on them is not the wall; wait for the
        // programmes before shooting it.
        guard !autopilotRan, !bands.isEmpty else { return }
        autopilotRan = true
        guard let target = LiveWallAutopilot.target else { return }
        let row = min(max(target.row, 0), bands.count - 1)
        let column = min(max(target.column, 0), max(bands[row].cards.count - 1, 0))
        controller.focus(row: row, column: column, animated: false)

        guard LiveWallAutopilot.shotPath != nil || LiveWallAutopilot.benchSeconds != nil else { return }
        Task { @MainActor in
            // Programme stills arrive over the network; a shot taken before
            // they land is a picture of the placeholder, not of the wall.
            try? await Task.sleep(for: .seconds(LiveWallAutopilot.settleSeconds))
            report()
        }
    }

    /// Shoots the wall, times it, and prints the numbers the gauntlet judges.
    @MainActor
    private func report() {
        let scene = controller.scene
        let eye = controller.pointOfView
        print("wall-focus: row=\(controller.focusedRow) column=\(controller.focusedColumn) "
            + "band=\(bands.indices.contains(controller.focusedRow) ? bands[controller.focusedRow].name : "-") "
            + "asked=\(LiveWallAutopilot.target.map { "\($0.row)/\($0.column)" } ?? "-")")

        if let path = LiveWallAutopilot.shotPath {
            if !LiveWallCapture.shoot(
                scene: scene, pointOfView: eye,
                size: LiveWallAutopilot.shotSize, to: path) {
                print("wall-shot: failed \(path)")
            }

            // A second frame taken the instant after a step, before any reprint
            // can have landed. Whatever the cards show here is what the viewer
            // sees on every key press — it must never be white.
            controller.handle(.right)
            let stepPath = path.replacingOccurrences(of: ".png", with: "-step.png")
            if !LiveWallCapture.shoot(
                scene: scene, pointOfView: eye,
                size: LiveWallAutopilot.shotSize, to: stepPath) {
                print("wall-shot: failed \(stepPath)")
            }
            controller.handle(.left)
        }

        // What the wall actually has to work with: a card with no programme has
        // no title, no hours and no picture of its own.
        let all = bands.flatMap(\.cards)
        let programme = all.filter { $0.program != nil }.count
        let progress = all.filter { $0.progress != nil }.count
        let art = all.filter { $0.artwork != nil }.count
        let logos = all.filter { $0.artworkIsLogo && $0.artwork != nil }.count
        let names = bands.map(\.name).joined(separator: " / ")
        print("wall-data: cards=\(all.count) programme=\(programme) progress=\(progress) "
            + "art=\(art) logo=\(logos) onNow=\(onNow.programs.count) "
            + "fetched=\(onNow.fetchedCount) bands=\(names)")
        print("wall-epg: sample=\(onNow.sampleWindow) err=\(onNow.errorMessage ?? "-") "
            + "now=\(ISO8601DateFormatter().string(from: Date()))")

        if let seconds = LiveWallAutopilot.benchSeconds {
            // A focus step is the whole cost of moving: the layout, the reprint
            // scheduling, and the frame that comes out the other side.
            let stepStart = CACurrentMediaTime()
            controller.handle(.right)
            let stepMilliseconds = (CACurrentMediaTime() - stepStart) * 1000
            controller.handle(.left)

            if let timing = LiveWallCapture.benchmark(
                scene: scene, pointOfView: eye,
                size: LiveWallAutopilot.benchSize, seconds: seconds) {
                let size = LiveWallAutopilot.benchSize
                print(String(
                    format: "wall-bench: %.0fx%.0f frames=%d avgFPS=%.1f p95=%.2fms worst=%.2fms focusStep=%.2fms channels=%d",
                    size.width, size.height, timing.frames, timing.averageFPS,
                    timing.p95FrameMilliseconds, timing.worstFrameMilliseconds,
                    stepMilliseconds, bands.reduce(0) { $0 + $1.cards.count }))
            }
        }

        LiveWallAutopilot.quitIfAsked()
    }
    #endif
}
