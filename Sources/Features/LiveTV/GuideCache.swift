import CryptoKit
import Foundation

/// Account-scoped guide snapshots. Disk IO and Codable work stay off the UI actor.
actor GuideCache {
    static let shared = GuideCache()
    private let directory: URL

    struct Snapshot: Codable {
        var savedAt: Date
        var windowStart: Date
        var windowEnd: Date
        var channels: [BaseItem]
        var programs: [String: [BaseItem]]

        func isUsable(at now: Date) -> Bool {
            savedAt <= now.addingTimeInterval(60)
                && now.timeIntervalSince(savedAt) < 24 * 3600
                && windowStart <= now && windowEnd > now.addingTimeInterval(30 * 60)
                && !channels.isEmpty
        }
    }

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VlinderGuide", isDirectory: true)) {
        self.directory = directory
    }

    private func file(for identity: String) -> URL {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(identity: String, now: Date) -> Snapshot? {
        guard let data = try? Data(contentsOf: file(for: identity)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.isUsable(at: now) else { return nil }
        return snapshot
    }

    func save(_ snapshot: Snapshot, identity: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: identity), options: .atomic)
        } catch {
            // A cache failure must never interrupt live listings.
        }
    }
}
