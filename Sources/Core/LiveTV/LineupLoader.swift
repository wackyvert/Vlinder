import Foundation

/// Loads and caches the external channel lineup used to group the TV guide.
///
/// Port of Tuner's LineupLoader (itself a port of Fladder's
/// live_tv_lineup_provider.dart): the lineup source URL is fetched with a
/// plain HTTP GET — it is NOT a Jellyfin endpoint, so no auth headers — and
/// the RAW payload text is cached on disk so grouping keeps working when the
/// source host (e.g. a LAN-only relay) is unreachable. On any fetch/parse
/// failure the previous cached lineup is kept and returned.
final class LineupLoader: @unchecked Sendable {
    static let shared = LineupLoader()

    static let cacheFileName = "live_tv_lineup.cache"
    /// forceRefresh=false serves a cache younger than this without fetching.
    static let cacheFreshnessWindow: TimeInterval = 15 * 60
    static let requestTimeout: TimeInterval = 10

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Synchronously returns the disk-cached lineup, if any.
    /// Empty urlString → nil (mirrors Dart clearing state when unset).
    func cached(urlString: String) -> ChannelLineup? {
        guard !urlString.isEmpty else { return nil }
        guard
            let cacheURL = cacheFileURL(),
            let content = try? String(contentsOf: cacheURL, encoding: .utf8),
            let lineup = ChannelLineup.parse(content),
            !lineup.isEmpty
        else { return nil }
        return lineup
    }

    func load(urlString: String, forceRefresh: Bool) async -> ChannelLineup? {
        // Dart: empty URL clears state (the stale cache file is left behind).
        guard !urlString.isEmpty else { return nil }

        if !forceRefresh, let fresh = freshCachedLineup(urlString: urlString) {
            return fresh
        }

        // Dart: Uri.tryParse + hasScheme guard → failure keeps previous state.
        guard let url = URL(string: urlString), url.scheme?.isEmpty == false else {
            return cached(urlString: urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return cached(urlString: urlString)
            }
            let body = String(decoding: data, as: UTF8.self)
            guard let lineup = ChannelLineup.parse(body), !lineup.isEmpty else {
                // Parsed to nothing usable — keep whatever we had before.
                return cached(urlString: urlString)
            }
            // Success: overwrite the cache with the raw payload (like Dart).
            if let cacheURL = cacheFileURL() {
                try? body.write(to: cacheURL, atomically: true, encoding: .utf8)
            }
            return lineup
        } catch {
            return cached(urlString: urlString)
        }
    }

    // MARK: - Cache file

    private func cacheFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent(Self.cacheFileName)
    }

    private func freshCachedLineup(urlString: String) -> ChannelLineup? {
        guard
            let cacheURL = cacheFileURL(),
            let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
            let modified = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < Self.cacheFreshnessWindow
        else { return nil }
        return cached(urlString: urlString)
    }
}
