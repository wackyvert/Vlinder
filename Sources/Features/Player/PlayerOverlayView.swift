import AVKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Full-window playback surface layered over the app (native transport controls
/// from AVKit; custom chrome for close/guide/next/previous).
///
/// On macOS the player takes the window over entirely — see `PlayerWindowChrome`
/// — and its chrome fades out with the pointer so the video is the only thing
/// left on screen, matching the auto-hide of AVKit's own floating controls.
///
/// On tvOS there is no pointer to fade against and no place for a floating
/// button row a Siri Remote could reach, so the whole surface is handed to
/// `AVPlayerViewController` presented the way the system's own players are:
/// transport and scrubbing from AVKit, Menu dismisses, and the app's actions
/// (guide, next/previous) sit in the transport bar's custom menu. See
/// `TVPlayerSurface`.
struct PlayerOverlayView: View {
    /// Idle time before the chrome fades, tuned to sit alongside AVKit's own
    /// floating-controls timeout rather than fight it.
    private static let idleBeforeHide = Duration.seconds(3)

    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var app
    @Environment(GuideModel.self) private var guide
    @State private var showGuide = false
    @State private var chromeVisible = true
    @State private var pointerInChrome = false
    @State private var hideTask: Task<Void, Never>?
    @State private var lastPointerActivity: ContinuousClock.Instant?

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        desktopBody
        #endif
    }

    #if os(tvOS)
    /// AVKit owns the screen for the whole life of a tune — loading included,
    /// so surfing channels from the guide never drops back to the SwiftUI layer
    /// and re-presents the player. SwiftUI paints only the one state AVKit has
    /// nothing for: failure, where a focusable Close is the sole control.
    private var tvBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if case .failed = coordinator.state {
                statusOverlay
            } else {
                TVPlayerSurface(
                    player: coordinator.player,
                    title: TVTitle.sanitize(coordinator.title),
                    subtitle: coordinator.subtitle,
                    isLive: coordinator.isLive,
                    isPlaying: coordinator.state == .playing,
                    artwork: coordinator.tuningArtwork,
                    hasPrevious: coordinator.hasPreviousInQueue,
                    hasNext: coordinator.hasNextInQueue,
                    canSurf: coordinator.isLive && surfChannels.count > 1,
                    canRestartFromBeginning: coordinator.canRestartFromBeginning,
                    onPrevious: { coordinator.playPreviousInQueue() },
                    onNext: { coordinator.playNextInQueue() },
                    onStepChannel: { stepChannel($0) },
                    onRestartFromBeginning: { coordinator.restartFromBeginning() },
                    onDismiss: { coordinator.dismiss() },
                    guideRoot: { dismissGuide in
                        AnyView(inPlayerGuide(dismiss: dismissGuide))
                    })
                    .ignoresSafeArea()
            }
        }
        // Menu while our own view holds focus (failure) leaves the player, the
        // same way it leaves AVKit's controller.
        .onExitCommand { coordinator.dismiss() }
        // Channel surfing walks the guide's rows, which exist only once the
        // guide has loaded; a deep-link tune (Siri, top shelf, the harness)
        // reaches the player without ever having shown the guide.
        .task(id: coordinator.isLive) {
            guard coordinator.isLive, let client = app.client else { return }
            await guide.ensureFresh(client: client, settings: app.settings)
        }
    }

    /// The guide as the Apple TV app and Infuse present theirs: the stream
    /// stays live behind it. The top of the frame is left to the picture under
    /// a light scrim; the rows sit lower under a heavier one, so their type
    /// stays legible over whatever is playing.
    private func inPlayerGuide(dismiss: @escaping () -> Void) -> some View {
        GuideView(
            onChannelSelected: { channel in
                dismiss()
                if let client = app.client {
                    coordinator.playChannel(channel, client: client, settings: app.settings)
                }
            },
            initialChannelId: coordinator.isLive ? coordinator.currentItemId : nil,
            transparentBackground: true)
            .environment(app)
            .environment(coordinator)
            .environment(guide)
            .padding(.top, Self.inPlayerGuideTopInset)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.18), location: 0),
                        .init(color: .black.opacity(0.35), location: 0.22),
                        .init(color: .black.opacity(0.82), location: 0.34),
                        .init(color: .black.opacity(0.9), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            .onExitCommand { dismiss() }
    }

    /// Picture left uncovered above the in-player guide (of a 1080 frame).
    private static let inPlayerGuideTopInset: CGFloat = 300

    /// Channels in the order the guide lists them — lineup groups in source
    /// order, provider order within a group — with every group expanded, so a
    /// surf never skips a channel a collapsed header happens to hide.
    private var surfChannels: [BaseItem] {
        guide.rows(collapsedGroups: [], searchTerm: "", playingChannelId: nil).compactMap { row in
            if case .channel(let channel) = row { channel } else { nil }
        }
    }

    /// Step to the row above (-1) or below (+1) the playing channel, wrapping
    /// at the ends the way a set-top box does.
    private func stepChannel(_ delta: Int) {
        guard let client = app.client, let current = coordinator.currentItemId else { return }
        let channels = surfChannels
        guard channels.count > 1, let index = channels.firstIndex(where: { $0.id == current }) else { return }
        let next = channels[(index + delta + channels.count) % channels.count]
        coordinator.playChannel(next, client: client, settings: app.settings)
    }
    #else
    private var desktopBody: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            // Attach the surface as soon as the player exists: AVKit's views
            // handle the pre-ready phase themselves, and attaching early avoids
            // the HLS video-selection quirks of a late-attached layer.
            if let player = coordinator.player,
               coordinator.state == .playing || coordinator.state == .loading {
                VideoSurface(player: player)
                    .ignoresSafeArea()
            }

            statusOverlay

            topScrim
            chrome
        }
        #if os(macOS)
        .background(PlayerWindowChrome().frame(width: 0, height: 0))
        .background(PointerActivityMonitor { pointerMoved() })
        .onExitCommand { coordinator.dismiss() }
        .onAppear { revealChrome() }
        .onDisappear { cancelHide() }
        // Loading and error states are worth reading, and the guide sheet owns
        // the pointer while it is up — none of them should fade.
        .onChange(of: coordinator.state) { revealChrome() }
        .onChange(of: showGuide) { revealChrome() }
        #endif
        .sheet(isPresented: $showGuide) { guideSheet }
    }
    #endif

    // MARK: - Chrome

    private var topScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.7), .black.opacity(0.25), .clear],
            startPoint: .top,
            endPoint: .bottom)
            .frame(height: 150)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(chromeVisible ? 1 : 0)
            .animation(fade, value: chromeVisible)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            chromeRow
            Spacer(minLength: 0)
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(fade, value: chromeVisible)
    }

    private var chromeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            chromeButton("xmark", help: "Close player") { coordinator.dismiss() }
                #if !os(tvOS)
                .keyboardShortcut(.escape, modifiers: [])
                #endif

            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = coordinator.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.top, 3)
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)

            Spacer(minLength: 12)

            if coordinator.isLive {
                chromeButton("rectangle.grid.1x2", help: "TV guide") { showGuide = true }
            }
            if coordinator.hasPreviousInQueue {
                chromeButton("backward.end.fill", help: "Previous") { coordinator.playPreviousInQueue() }
            }
            if coordinator.hasNextInQueue {
                chromeButton("forward.end.fill", help: "Next") { coordinator.playNextInQueue() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        #if os(macOS)
        // Reaching for a button must not start the fade out from under it.
        .onHover { hovering in
            pointerInChrome = hovering
            if hovering {
                cancelHide()
            } else {
                scheduleHide()
            }
        }
        #endif
    }

    private func chromeButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch coordinator.state {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(coordinator.isLive ? "Tuning \(coordinator.title)…" : "Loading \(coordinator.title)…")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Close") { coordinator.dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            EmptyView()
        }
    }

    private var guideSheet: some View {
        NavigationStack {
            GuideView(onChannelSelected: { channel in
                showGuide = false
                if let client = app.client {
                    coordinator.playChannel(channel, client: client, settings: app.settings)
                }
            })
            .navigationTitle("TV Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showGuide = false }
                }
            }
            #else
            .toolbar {
                Button("Close") { showGuide = false }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 560)
        #endif
    }

    // MARK: - Auto-hide

    private var fade: Animation {
        .easeInOut(duration: chromeVisible ? 0.15 : 0.4)
    }

    /// Pointer activity brings the chrome back and restarts the idle clock.
    /// This runs at mouse-event rate, so it declines to touch state or rebuild
    /// the timer when neither actually needs it — a `@State` write here would
    /// re-evaluate the whole overlay a hundred times a second.
    private func pointerMoved() {
        #if os(macOS)
        let now = ContinuousClock.now
        if chromeVisible, hideTask != nil, let last = lastPointerActivity, now - last < .milliseconds(250) {
            return
        }
        lastPointerActivity = now
        revealChrome()
        #endif
    }

    private func revealChrome() {
        #if os(macOS)
        if !chromeVisible { chromeVisible = true }
        scheduleHide()
        #endif
    }

    private func scheduleHide() {
        #if os(macOS)
        cancelHide()
        guard coordinator.state == .playing, !showGuide, !pointerInChrome else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleBeforeHide)
            guard !Task.isCancelled else { return }
            chromeVisible = false
            // Restores itself on the next movement, which also un-hides the chrome.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        #endif
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}

#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // Live Text / subject lift on a paused frame is noise in a TV client.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        #if DEBUG
        context.coordinator.beginDiagnostics(for: view)
        #endif
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// DEBUG-only: periodically logs whether AVPlayerView is actually giving
    /// the video any pixels (videoBounds zero = rendering no video).
    final class Coordinator {
        private var timer: Timer?

        func beginDiagnostics(for view: AVPlayerView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak view] _ in
                guard let view else { return }
                let bounds = view.videoBounds
                let size = view.player?.currentItem?.presentationSize ?? .zero
                NSLog("[Vlinder] AVPlayerView videoBounds=%.0fx%.0f frame=%.0fx%.0f inWindow=%d item=%.0fx%.0f",
                      bounds.width, bounds.height,
                      view.frame.width, view.frame.height,
                      view.window != nil ? 1 : 0,
                      size.width, size.height)
            }
        }

        deinit { timer?.invalidate() }
    }
}
#elseif os(iOS)
struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
#else
/// tvOS playback surface. `AVPlayerViewController` is *presented* rather than
/// embedded: presented is the shape tvOS's Menu handling is built around
/// (Menu hides the transport bar, Menu again dismisses the player) and it is
/// what every system player does, so the remote behaves the way the viewer
/// already expects. The controller lives for the whole overlay — the player
/// under it is swapped on every tune — so surfing channels never flashes back
/// to SwiftUI, and the resolving phase reads as "Tuning…" on the controller's
/// own overlay rather than a black screen.
struct TVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer?
    let title: String
    let subtitle: String?
    let isLive: Bool
    let isPlaying: Bool
    let artwork: PlayerCoordinator.TuningArtwork?
    let hasPrevious: Bool
    let hasNext: Bool
    let canSurf: Bool
    let canRestartFromBeginning: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    /// -1 = the guide row above the playing channel, +1 = the row below.
    let onStepChannel: (Int) -> Void
    let onRestartFromBeginning: () -> Void
    let onDismiss: () -> Void
    /// Builds the guide to present over the player; the argument closes it.
    let guideRoot: (@escaping () -> Void) -> AnyView

    func makeUIViewController(context: Context) -> TVPlayerHost {
        let host = TVPlayerHost()
        apply(to: host)
        return host
    }

    func updateUIViewController(_ host: TVPlayerHost, context: Context) {
        apply(to: host)
    }

    static func dismantleUIViewController(_ host: TVPlayerHost, coordinator: ()) {
        host.tearDown()
    }

    private func apply(to host: TVPlayerHost) {
        host.onDismiss = onDismiss
        host.onPrevious = onPrevious
        host.onNext = onNext
        host.onStepChannel = onStepChannel
        host.onRestartFromBeginning = onRestartFromBeginning
        host.guideRoot = guideRoot
        host.configure(
            player: player,
            metadata: TVPlayerHost.Metadata(title: title, subtitle: subtitle, isLive: isLive),
            artwork: artwork,
            isPlaying: isPlaying,
            actions: TVPlayerHost.Actions(
                hasPrevious: hasPrevious, hasNext: hasNext,
                canSurf: canSurf, canRestartFromBeginning: canRestartFromBeginning))
    }
}

/// Channel names as an IPTV provider ships them ("US: TUDN EXTRA 2 ᴿᴬᵂ",
/// "ESPN HD [Backup]") read as inventory, not as a channel, at 43pt on a
/// television. This is the TV presentation only — the guide, the Mac and iOS
/// keep `BaseItem.displayTitle` verbatim so the name still matches the server.
enum TVTitle {
    /// Provider superscript feed tags, folded to plain letters so the trailing
    /// tag rule below catches them.
    private static let superscripts: [Character: Character] = [
        "ᴬ": "A", "ᴮ": "B", "ᶜ": "C", "ᴰ": "D", "ᴱ": "E", "ᶠ": "F", "ᴳ": "G", "ᴴ": "H",
        "ᴵ": "I", "ᴶ": "J", "ᴷ": "K", "ᴸ": "L", "ᴹ": "M", "ᴺ": "N", "ᴼ": "O", "ᴾ": "P",
        "ᴿ": "R", "ˢ": "S", "ᵀ": "T", "ᵁ": "U", "ⱽ": "V", "ᵂ": "W",
    ]
    private static let rules: [NSRegularExpression] = [
        // Bracketed feed tags anywhere: "[Backup]", "(Feed 2)".
        "\\s*[\\[\\(][^\\]\\)]*[\\]\\)]",
        // Provider/country prefix: "US:", "UK |", "USA -".
        "^\\s*[A-Z]{2,3}\\s*[:|\\-]\\s*",
        // Trailing quality and feed tags, any number of them.
        "(?:\\s+(?:HD|FHD|UHD|SD|4K|8K|RAW|HEVC|H\\.?265|BACKUP|VIP|ALT|FEED\\s*\\d*))+\\s*$",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func sanitize(_ raw: String) -> String {
        var text = String(raw.map { superscripts[$0] ?? $0 })
        for rule in rules {
            text = rule.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Never sanitize a name down to nothing — fall back to what the server said.
        return text.isEmpty ? raw : text
    }
}

/// Invisible host that presents the real player controller once it is in a
/// window, and mirrors the coordinator's state onto it thereafter.
final class TVPlayerHost: UIViewController, AVPlayerViewControllerDelegate {
    struct Metadata: Equatable {
        var title: String
        var subtitle: String?
        var isLive: Bool
    }

    struct Actions: Equatable {
        var hasPrevious = false
        var hasNext = false
        var canSurf = false
        var canRestartFromBeginning = false
    }

    var onDismiss: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onStepChannel: (Int) -> Void = { _ in }
    var onRestartFromBeginning: () -> Void = {}
    var guideRoot: ((@escaping () -> Void) -> AnyView)?

    private let controller = TVPlayerController()
    private let tuningView = TuningView()
    private var metadata: Metadata?
    private var actions = Actions()
    private var didPresent = false
    private var tornDown = false
    /// AVKit tells its delegate when the transport bar comes and goes; that is
    /// the only signal for whether an up/down click belongs to the bar.
    private var transportBarVisible = false
    private var surfDeltas: [ObjectIdentifier: Int] = [:]
    #if DEBUG
    private var didAutoShowGuide = false
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // A plain full-screen presentation takes the presenting hierarchy —
        // this SwiftUI-hosted view — out of the window, and SwiftUI stops
        // updating a detached view, so the player the coordinator creates a
        // moment later would never reach the controller. Over-full-screen
        // keeps this view resident (and black) underneath.
        controller.modalPresentationStyle = .overFullScreen
        controller.delegate = self
        controller.onUserDismissed = { [weak self] in
            guard let self, !self.tornDown else { return }
            self.onDismiss()
        }
        installSurfRecognizers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent, !tornDown else { return }
        didPresent = true
        // No animation: the SwiftUI overlay already faded the screen to black.
        present(controller, animated: false)
        installTuningView()
    }

    func configure(player: AVPlayer?, metadata: Metadata, artwork: PlayerCoordinator.TuningArtwork?,
                   isPlaying: Bool, actions: Actions) {
        if controller.player !== player {
            controller.player = player
        }
        var menuStale = false
        // AVKit reads the title for its transport overlay from the item, so
        // re-stamp whenever the coordinator moves to a new one.
        if self.metadata != metadata || player?.currentItem?.externalMetadata.isEmpty == true {
            self.metadata = metadata
            player?.currentItem?.externalMetadata = Self.metadataItems(metadata)
            tuningView.text = metadata.isLive ? "Tuning \(metadata.title)…" : "Loading \(metadata.title)…"
            menuStale = true
        }
        if self.actions != actions {
            self.actions = actions
            menuStale = true
        }
        if menuStale {
            controller.transportBarCustomMenuItems = menuItems(live: metadata.isLive)
            controller.infoViewActions = infoActions(live: metadata.isLive)
        }
        tuningView.artwork = artwork
        tuningView.isHidden = isPlaying
        #if DEBUG
        NSLog("[Vlinder] tv-host configure playing=%d player=%@ item=%ld ready=%d presented=%d overlay=%@",
              isPlaying ? 1 : 0, player.map { "\(ObjectIdentifier($0))" } ?? "nil",
              player?.currentItem?.status.rawValue ?? -1, controller.isReadyForDisplay ? 1 : 0,
              controller.presentingViewController != nil ? 1 : 0,
              tuningView.superview.map { NSCoder.string(for: $0.bounds) } ?? "none")
        if isPlaying, PlaybackAutopilot.showsGuide, !didAutoShowGuide {
            didAutoShowGuide = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.presentGuide() }
        }
        #endif
    }

    /// The SwiftUI side is gone (failure, playback ended, dismissed from
    /// elsewhere): take the presented controller down with it and stop
    /// treating its disappearance as the user leaving.
    func tearDown() {
        tornDown = true
        controller.player = nil
        if controller.presentingViewController != nil {
            controller.dismiss(animated: false)
        }
    }

    /// AVKit's `contentOverlayView` sits between the video and the transport
    /// bar, so "Tuning…" shows the moment a channel is picked and the bar
    /// still lands on top of it. The tuning view fills the overlay: it paints
    /// the channel's mark and programme picture, not just a spinner on black.
    private func installTuningView() {
        guard let overlay = controller.contentOverlayView, tuningView.superview == nil else { return }
        overlay.addSubview(tuningView)
        tuningView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tuningView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            tuningView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            tuningView.topAnchor.constraint(equalTo: overlay.topAnchor),
            tuningView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])
    }

    // MARK: Channel surf

    /// Clicking the remote's up/down edges while the transport bar is hidden
    /// is the set-top-box gesture for changing channel, and AVKit has nothing
    /// of its own on those presses in that state. With the bar up they belong
    /// to AVKit (down opens the info panel), so they are left alone then.
    private func installSurfRecognizers() {
        for (pressType, delta) in [(UIPress.PressType.upArrow, -1), (.downArrow, 1)] {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(surfPress(_:)))
            recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            recognizer.cancelsTouchesInView = false
            surfDeltas[ObjectIdentifier(recognizer)] = delta
            controller.view.addGestureRecognizer(recognizer)
        }
    }

    @objc private func surfPress(_ recognizer: UITapGestureRecognizer) {
        guard metadata?.isLive == true, actions.canSurf, !transportBarVisible,
              controller.presentedViewController == nil,
              let delta = surfDeltas[ObjectIdentifier(recognizer)] else { return }
        onStepChannel(delta)
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willTransitionToVisibilityOfTransportBar visible: Bool,
        with coordinator: any AVPlayerViewControllerAnimationCoordinator
    ) {
        transportBarVisible = visible
    }

    // MARK: Actions

    private func menuItems(live: Bool) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if live {
            items.append(UIAction(
                title: "TV Guide", image: UIImage(systemName: "rectangle.grid.1x2")
            ) { [weak self] _ in self?.presentGuide() })
            if actions.canSurf {
                // Labelled by direction in the guide, not by channel number:
                // the lineup is grouped, so "up" is the row above, as the eye
                // reads it, whatever the numbers do.
                items.append(UIAction(
                    title: "Channel Up", image: UIImage(systemName: "chevron.up")
                ) { [weak self] _ in self?.onStepChannel(-1) })
                items.append(UIAction(
                    title: "Channel Down", image: UIImage(systemName: "chevron.down")
                ) { [weak self] _ in self?.onStepChannel(1) })
            }
        }
        if actions.canRestartFromBeginning {
            // A transcode resume starts the HLS timeline at the resume point;
            // AVKit cannot scrub before it. Say so with a way out rather than
            // letting the scrubber imply the head is reachable.
            items.append(UIAction(
                title: "From Beginning", image: UIImage(systemName: "backward.end.alt.fill")
            ) { [weak self] _ in self?.onRestartFromBeginning() })
        }
        if actions.hasPrevious {
            items.append(UIAction(
                title: "Previous Episode", image: UIImage(systemName: "backward.end.fill")
            ) { [weak self] _ in self?.onPrevious() })
        }
        if actions.hasNext {
            items.append(UIAction(
                title: "Next Episode", image: UIImage(systemName: "forward.end.fill")
            ) { [weak self] _ in self?.onNext() })
        }
        return items
    }

    /// The Info panel (swipe down) is where tvOS viewers look for "what else
    /// can I do here", so the same actions live there as full-width buttons.
    private func infoActions(live: Bool) -> [UIAction] {
        menuItems(live: live).compactMap { $0 as? UIAction }
    }

    /// The guide rides on top of the player as its own modal, so the stream
    /// keeps playing underneath and Menu peels it away without leaving the
    /// player — the same surf-then-return the Mac's sheet gives. The hosting
    /// view is clear: the guide root paints its own scrim, and the video
    /// shows through it the way it does behind the TV app's channel list.
    private func presentGuide() {
        guard let guideRoot, controller.presentedViewController == nil else { return }
        weak var presented: UIViewController?
        let root = guideRoot {
            presented?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        // Over-full-screen for the same reason the host presents the player
        // that way: a plain full-screen guide would pull the player controller
        // out of the window, and AVKit stops rendering a detached controller.
        host.modalPresentationStyle = .overFullScreen
        presented = host
        // Not animated: while a modal transition runs UIKit keeps focus on the
        // player, and SwiftUI drops the guide's programmatic first focus (the
        // tuned channel's cell) on the floor, leaving it on the day pill.
        controller.present(host, animated: false)
    }

    private static func metadataItems(_ metadata: Metadata) -> [AVMetadataItem] {
        var items = [metadataItem(.commonIdentifierTitle, metadata.title)]
        if let subtitle = metadata.subtitle, !subtitle.isEmpty {
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, subtitle))
        }
        return items
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

/// The stretch between picking something and its first frame. Fills the
/// player: the programme picture (or backdrop) dimmed across the frame, the
/// channel's mark (or poster) over it, then the spinner and caption — so the
/// viewer sees *what* is tuning, not a spinner on black.
final class TuningView: UIView {
    private let backdrop = UIImageView()
    private let dim = UIView()
    private let mark = UIImageView()
    private let label = UILabel()
    private var loadTask: Task<Void, Never>?

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    var artwork: PlayerCoordinator.TuningArtwork? {
        didSet {
            guard artwork != oldValue else { return }
            loadArtwork()
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        // Dim, not blur: a blur on the simulator's software path costs frames
        // during the one moment the app must feel responsive.
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        mark.contentMode = .scaleAspectFit
        // No spinner of our own: AVKit draws its loading indicator in the
        // same spot once the player is attached, and two spinners stacked
        // read as a glitch. The caption's ellipsis carries the "working" cue
        // for the moment before the player exists.
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        for view in [backdrop, dim, mark, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The mark sits a little above centre so mark + spinner + caption
            // read as one centred group.
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -150),
            mark.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            mark.heightAnchor.constraint(equalToConstant: 220),
            // Leaves the gap where AVKit centres its own indicator.
            label.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 150),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
        ])
    }

    required init(coder: NSCoder) { fatalError("unused") }

    private func loadArtwork() {
        loadTask?.cancel()
        backdrop.image = nil
        mark.image = nil
        guard let artwork else { return }
        loadTask = Task { @MainActor [weak self] in
            // Mark first: it is small and it is the thing that names the channel.
            if let url = artwork.mark, let image = try? await ImageLoader.shared.load(url), !Task.isCancelled {
                self?.mark.image = image
            }
            if let url = artwork.backdrop, let image = try? await ImageLoader.shared.load(url), !Task.isCancelled {
                self?.backdrop.image = image
            } else if artwork.backdrop == nil, let url = artwork.mark,
                      let image = try? await ImageLoader.shared.load(url), !Task.isCancelled {
                // No programme picture: the mark itself, blown up and dimmed,
                // gives the frame the channel's colour instead of black.
                self?.backdrop.image = image
            }
        }
    }
}

/// Reports when the *viewer* dismissed it (Menu with the transport bar
/// hidden), as opposed to the host taking it down.
final class TVPlayerController: AVPlayerViewController {
    var onUserDismissed: () -> Void = {}
    private var dismissing = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { dismissing = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if dismissing {
            dismissing = false
            onUserDismissed()
        }
    }
}
#endif
