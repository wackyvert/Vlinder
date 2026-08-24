import AVKit
import SwiftUI

/// Full-window playback surface layered over the app (native transport controls
/// from AVKit; custom chrome for close/next/previous).
struct PlayerOverlayView: View {
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var app
    @State private var showGuide = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Attach the surface as soon as the player exists: AVKit's views
            // handle the pre-ready phase themselves, and attaching early avoids
            // the HLS video-selection quirks of a late-attached layer.
            if let player = coordinator.player,
               coordinator.state == .playing || coordinator.state == .loading {
                VideoSurface(player: player)
                    .ignoresSafeArea()
            }

            switch coordinator.state {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(coordinator.isLive ? "Tuning \(coordinator.title)…" : "Loading \(coordinator.title)…")
                        .foregroundStyle(.white.opacity(0.85))
                }
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
            default:
                EmptyView()
            }

            chrome
        }
        #if os(macOS)
        .onExitCommand { coordinator.dismiss() }
        #endif
        .sheet(isPresented: $showGuide) {
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
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    coordinator.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle = coordinator.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .shadow(radius: 4)

                Spacer()

                if coordinator.isLive {
                    queueButton(systemImage: "rectangle.grid.1x2") {
                        showGuide = true
                    }
                }
                if coordinator.hasPreviousInQueue {
                    queueButton(systemImage: "backward.end.fill") {
                        coordinator.playPreviousInQueue()
                    }
                }
                if coordinator.hasNextInQueue {
                    queueButton(systemImage: "forward.end.fill") {
                        coordinator.playNextInQueue()
                    }
                }
            }
            .padding(16)
            Spacer()
        }
    }

    private func queueButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .padding(10)
                .background(.black.opacity(0.5), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
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
#else
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
#endif
