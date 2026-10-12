import Foundation

/// The App Group both the app and its extensions read. Must match the
/// `com.apple.security.application-groups` entitlement on every target.
enum AppGroup {
    static let identifier = "group.dev.jake.vlinder"

    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}

/// Session hand-off from the app to the Top Shelf and Intents extensions.
///
/// The extensions cannot read `SessionStore`'s own storage: the Keychain item
/// lives in the app's default access group (a different bundle id ⇒ a different
/// group), and its unsigned-dev-build fallback lands in the *app's*
/// `UserDefaults.standard` domain. So the app mirrors whatever `SessionStore`
/// currently holds into the shared App Group on every launch, and extensions
/// read only from there. Nothing here ever re-prompts sign-in: with no mirror,
/// an extension simply publishes nothing.
enum SharedSession {
    private static let key = "vlinder.shared.session"

    /// Called by the app. Idempotent; a no-op when nothing has changed, so the
    /// group container is not rewritten on every cold start.
    static func mirrorFromSessionStore() {
        let stored = SessionStore.load()
        guard let active = stored.accounts.first(where: { $0.id == stored.activeId })
            ?? stored.accounts.first,
            let data = try? JSONEncoder().encode(active),
            let defaults = defaults
        else { return }
        guard defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }

    /// Called by the extensions — and by App Intents, which run in the app's own
    /// process on platforms with no App Group (macOS), hence the fallback to the
    /// real store. In an extension that fallback finds nothing, which is the
    /// correct answer there.
    static func load() -> Session? {
        if let data = defaults?.data(forKey: key),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            return session
        }
        let stored = SessionStore.load()
        if let session = stored.accounts.first(where: { $0.id == stored.activeId })
            ?? stored.accounts.first {
            return session
        }
        #if targetEnvironment(simulator) && DEBUG
        return simulatorAppPreferences()
        #else
        return nil
        #endif
    }

    #if targetEnvironment(simulator) && DEBUG
    /// The tvOS Simulator ad-hoc-signs without embedding entitlements, so
    /// neither the app nor the extension is actually granted the App Group
    /// there — `UserDefaults(suiteName:)` writes into a domain that never
    /// exists, and the shelf would be permanently empty on the only machine it
    /// can be looked at. On a real Apple TV the group is granted and the mirror
    /// above answers first, so this is never reached.
    ///
    /// The simulator, unlike the device, leaves other apps' containers readable
    /// from an extension, so the app's own preferences file can be found by
    /// walking up out of this plug-in's container.
    private static func simulatorAppPreferences() -> Session? {
        let containers = URL(fileURLWithPath: NSHomeDirectory())
            .deletingLastPathComponent()   // .../Containers/Data/PluginKitPlugin
            .deletingLastPathComponent()   // .../Containers/Data
            .appendingPathComponent("Application")
        guard let apps = try? FileManager.default.contentsOfDirectory(
            at: containers, includingPropertiesForKeys: nil) else { return nil }
        for app in apps {
            let plist = app.appendingPathComponent(
                "Library/Preferences/dev.jake.vlinder.tv.plist")
            guard let data = try? Data(contentsOf: plist),
                  let root = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any],
                  let blob = root["vlinder.accounts.fallback"] as? Data,
                  let stored = try? JSONDecoder().decode(StoredAccounts.self, from: blob)
            else { continue }
            if let session = stored.accounts.first(where: { $0.id == stored.activeId })
                ?? stored.accounts.first {
                return session
            }
        }
        return nil
    }
    #endif

    static func clear() { defaults?.removeObject(forKey: key) }

    private static var defaults: UserDefaults? { AppGroup.defaults }

    /// A client built from the mirrored session, for use outside the app process.
    static func client() -> JellyfinClient? {
        guard let session = load() else { return nil }
        return client(for: session, url: session.serverURL)
    }

    /// Same, but first gives the account's LAN address a short chance to answer —
    /// mirroring `AppState.probeLocalURL`, so an extension on the same network
    /// talks to the server directly instead of looping out through the remote URL.
    static func clientPreferringLocal() async -> JellyfinClient? {
        guard let session = load() else { return nil }
        if let localURL = session.localURL {
            let probe = client(for: session, url: localURL)
            if (try? await probe.publicSystemInfo()) != nil { return probe }
        }
        return client(for: session, url: session.serverURL)
    }

    private static func client(for session: Session, url: URL) -> JellyfinClient {
        JellyfinClient(
            serverURL: url,
            deviceId: session.deviceId,
            accessToken: session.accessToken,
            userId: session.userId)
    }
}
