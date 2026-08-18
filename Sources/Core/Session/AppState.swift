import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase {
        case launching
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .launching
    private(set) var client: JellyfinClient?
    private(set) var session: Session?
    var settings: AppSettings {
        didSet { settings.save() }
    }

    init() {
        settings = AppSettings.load()
    }

    func restoreSession() {
        if let session = SessionStore.load() {
            adopt(session: session)
        } else {
            phase = .signedOut
        }
    }

    func adopt(session: Session) {
        self.session = session
        self.client = JellyfinClient(
            serverURL: session.serverURL,
            deviceId: session.deviceId,
            accessToken: session.accessToken,
            userId: session.userId)
        SessionStore.save(session)
        phase = .signedIn
    }

    func signOut() {
        // Best-effort server-side logout, then clear local state.
        if let client {
            Task.detached { try? await client.send(.post, path: "/Sessions/Logout") }
        }
        SessionStore.clear()
        session = nil
        client = nil
        phase = .signedOut
    }
}
