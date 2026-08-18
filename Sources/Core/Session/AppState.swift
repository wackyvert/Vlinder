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
    private(set) var accounts: [Session] = []
    private(set) var isLocked = false
    var settings: AppSettings {
        didSet { settings.save() }
    }

    init() {
        settings = AppSettings.load()
        isLocked = settings.appLockEnabled && AppLockStore.hasCode
    }

    func restoreSession() {
        let stored = SessionStore.load()
        accounts = stored.accounts
        if let activeId = stored.activeId,
           let active = stored.accounts.first(where: { $0.id == activeId }) {
            adopt(session: active)
        } else if let first = stored.accounts.first {
            adopt(session: first)
        } else {
            phase = .signedOut
        }
    }

    /// Sign in / switch to a session: upsert into saved accounts, persist,
    /// build the client (and swap to the LAN URL when it responds).
    func adopt(session: Session) {
        if let index = accounts.firstIndex(where: { $0.id == session.id }) {
            accounts[index] = session
        } else {
            accounts.append(session)
        }
        self.session = session
        persist()
        client = JellyfinClient(
            serverURL: session.serverURL,
            deviceId: session.deviceId,
            accessToken: session.accessToken,
            userId: session.userId)
        phase = .signedIn
        probeLocalURL(for: session)
    }

    func switchTo(accountId: String) {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        adopt(session: account)
    }

    /// Update the active account's LAN URL and re-resolve the client.
    func setLocalURL(_ url: URL?) {
        guard var session else { return }
        session.localURL = url
        adopt(session: session)
    }

    func removeAccount(accountId: String) {
        let wasActive = session?.id == accountId
        if wasActive, let client {
            Task.detached { try? await client.send(.post, path: "/Sessions/Logout") }
        }
        accounts.removeAll { $0.id == accountId }
        if wasActive {
            session = nil
            client = nil
        }
        persist()
        if wasActive {
            if let next = accounts.first {
                adopt(session: next)
            } else {
                phase = .signedOut
            }
        }
    }

    func signOut() {
        guard let session else {
            phase = .signedOut
            return
        }
        removeAccount(accountId: session.id)
    }

    /// Sign-out into the connect flow while keeping saved accounts.
    func showConnect() {
        phase = .signedOut
    }

    private func persist() {
        SessionStore.save(StoredAccounts(accounts: accounts, activeId: session?.id))
    }

    /// When the account has a LAN URL, race a public-info probe against it and
    /// swap the client over on success (Fladder's local/remote URL switching).
    private func probeLocalURL(for session: Session) {
        guard let localURL = session.localURL else { return }
        let probe = JellyfinClient(
            serverURL: localURL,
            deviceId: session.deviceId,
            accessToken: session.accessToken,
            userId: session.userId)
        Task { [weak self] in
            guard (try? await probe.publicSystemInfo()) != nil else { return }
            guard let self, self.session?.id == session.id else { return }
            self.client = probe
        }
    }

    // MARK: - App lock

    func unlock(code: String) -> Bool {
        guard AppLockStore.verify(code) else { return false }
        isLocked = false
        return true
    }

    func enableAppLock(code: String) {
        AppLockStore.setCode(code)
        settings.appLockEnabled = true
    }

    func disableAppLock() {
        AppLockStore.clearCode()
        settings.appLockEnabled = false
        isLocked = false
    }
}
