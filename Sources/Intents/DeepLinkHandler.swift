import Foundation
import Observation
import SwiftUI

/// Holds a link that arrived before the app was ready to play it.
///
/// A Top Shelf tile or a Siri phrase can launch the app cold, so the link
/// routinely lands while `AppState` is still restoring the session. The router
/// parks it; `DeepLinkHandler` drains it as soon as a client exists.
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    var pending: DeepLink?

    private init() {}

    func submit(_ link: DeepLink) { pending = link }

    func submit(url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        submit(link)
        return true
    }
}

/// Mirrors the session for the extensions and routes incoming deep links into
/// the existing `PlayerCoordinator`. Attached once, in `VlinderApp`.
struct DeepLinkHandler: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var router = DeepLinkRouter.shared

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                _ = router.submit(url: url)
            }
            // SiriKit's INPlayMediaIntent resolves in its extension and hands
            // playback back here as a user activity carrying the same link.
            #if os(tvOS)
            .onContinueUserActivity(PlayMediaIntentHandler.activityType) { activity in
                guard let raw = activity.userInfo?[PlayMediaIntentHandler.activityLinkKey] as? String,
                      let url = URL(string: raw)
                else { return }
                _ = router.submit(url: url)
            }
            #endif
            .onChange(of: router.pending) { _, _ in drain() }
            .onChange(of: app.phase == .signedIn) { _, _ in
                SharedSession.mirrorFromSessionStore()
                drain()
            }
            .task {
                SharedSession.mirrorFromSessionStore()
                #if DEBUG
                submitLaunchArgumentLink()
                #endif
                drain()
            }
    }

    #if DEBUG
    /// `-DeepLink vlinder://tune/<id>`: the same route a Top Shelf tile takes,
    /// reachable from a shot script.
    ///
    /// `simctl openurl` cannot be used for this on the simulator — tvOS puts an
    /// "Open in Vlinder?" system alert in front of an externally injected URL,
    /// and there is no way to press its button from `simctl`. A real Top Shelf
    /// tile's `TVTopShelfAction` opens the app with no such prompt, so the alert
    /// is an artifact of the injection, not of the link. This flag exercises
    /// `DeepLinkRouter` itself, which is the part shared by every entry point.
    private func submitLaunchArgumentLink() {
        guard let raw = UserDefaults.standard.string(forKey: "DeepLink"),
              let url = URL(string: raw)
        else { return }
        _ = router.submit(url: url)
    }
    #endif

    private func drain() {
        guard let link = router.pending, let client = app.client else { return }
        router.pending = nil
        let settings = app.settings
        Task { @MainActor in
            do {
                switch link {
                case .play(let itemId):
                    let item = try await client.item(id: itemId)
                    player.play(item: item, client: client, settings: settings)
                case .tune(let channelId):
                    let channel = try await client.item(id: channelId)
                    player.playChannel(channel, client: client, settings: settings)
                }
            } catch {
                // A stale Top Shelf tile (item deleted server-side) must not
                // strand the app on a spinner; the failure is the player's to
                // show, and there is nothing to retry.
                FileHandle.standardError.write(Data("deep link \(link): \(error)\n".utf8))
            }
        }
    }
}

extension View {
    func vlinderDeepLinks() -> some View { modifier(DeepLinkHandler()) }
}
