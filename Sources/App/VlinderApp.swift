import SwiftUI

@main
struct VlinderApp: App {
    @State private var appState = AppState()
    @State private var player = PlayerCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(player)
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
            switch app.phase {
            case .launching:
                CenteredProgressView()
            case .signedOut:
                ConnectView()
            case .signedIn:
                MainView()
            }

            if player.isPresented {
                PlayerOverlayView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.isPresented)
        .task { app.restoreSession() }
    }
}
