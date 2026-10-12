import SwiftUI

@main
struct VlinderApp: App {
    @State private var appState = AppState()
    @State private var player = PlayerCoordinator()
    @State private var guide = GuideModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                // Inside the environment, not outside it: the handler reads
                // AppState and PlayerCoordinator from the environment, and a
                // modifier attached after `.environment(...)` sits above them
                // in the tree — which crashed every launch on every platform
                // with "No Observable object of type AppState found".
                .vlinderDeepLinks()
                .environment(appState)
                .environment(player)
                .environment(guide)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 620)
                #endif
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        ZStack {
            if isOfflineGuide {
                #if os(tvOS)
                MainView()
                #else
                NavigationStack { GuideView() }
                    .ignoresSafeArea(.all)
                #endif
            } else if app.isLocked {
                PasscodeView()
            } else {
                switch app.phase {
                case .launching:
                    CenteredProgressView()
                case .signedOut:
                    ConnectView()
                case .signedIn:
                    #if DEBUG
                    if GuideAutopilot.isActive {
                        // No sidebar, no split view: the window *is* the pane
                        // under test, at exactly the reference's bounds. The
                        // top safe area goes too — NavigationStack reserves the
                        // titlebar's 32pt even once the titlebar is transparent,
                        // which shifts every row 32pt below the frame it is
                        // being measured against.
                        #if os(tvOS)
                        // The TV has no window to size: the shot is the real
                        // screen, tab bar and all, so it goes through MainView
                        // (which lands on Live TV when the autopilot is on).
                        MainView()
                        #else
                        NavigationStack { GuideView() }
                            .ignoresSafeArea(.all)
                        #endif
                    } else {
                        MainView()
                    }
                    #else
                    MainView()
                    #endif
                }

                if player.isPresented {
                    PlayerOverlayView()
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.isPresented)
        .preferredColorScheme(colorScheme)
        .task { if !isOfflineGuide { app.restoreSession() } }
        #if DEBUG && os(macOS)
        .onAppear {
            #if os(tvOS)
            let size: CGSize? = nil
            #else
            let size: CGSize? = GuideAutopilot.isActive
                ? GuideAutopilot.shotSize
                : AtriumAutopilot.windowSize
            #endif
            guard let size else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let window = NSApp.windows.first else { return }
                window.setFrame(
                    NSRect(x: 60, y: 80, width: size.width, height: size.height),
                    display: true)
                if GuideAutopilot.isActive {
                    // A shot window must not be remembered. Its titlebar-less
                    // frame was persisted on quit and restored on the next
                    // ordinary launch as a window that never appeared — the
                    // installed app opened to nothing after every harness run.
                    window.isRestorable = false
                    // The titlebar paints over the top 32pt of the frame, which
                    // the reference spends on the header's own breathing room —
                    // so a shot with chrome is 32pt shorter than the bar it is
                    // being judged against.
                    // Not merely transparent: a transparent titlebar still
                    // paints, and 32 of the 51pt the reference spends above
                    // the header strip came back as grey chrome.
                    window.styleMask.remove(.titled)
                    window.styleMask.insert(.fullSizeContentView)
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    for button in [NSWindow.ButtonType.closeButton,
                                   .miniaturizeButton, .zoomButton] {
                        window.standardWindowButton(button)?.isHidden = true
                    }
                }
            }
        }
        #endif
    }

    private var isOfflineGuide: Bool {
        #if DEBUG
        GuideAutopilot.isOffline
        #else
        false
        #endif
    }

    private var colorScheme: ColorScheme? {
        #if DEBUG
        #if !os(tvOS)
        if let forced = AtriumAutopilot.appearanceOverride, forced != .system {
            return forced == .dark ? .dark : .light
        }
        #endif
        #endif
        switch app.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
