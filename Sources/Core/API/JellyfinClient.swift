import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Async Jellyfin API client.
///
/// Transport, URL handling, auth headers, Quick Connect, and the live TV stream
/// resolution are ported from Tuner's proven implementation (JellyfinClient.swift /
/// JellyfinRequests.swift there) — that logic is known-good against Jake's server.
final class JellyfinClient: @unchecked Sendable {
    let serverURL: URL
    let deviceId: String

    private let lock = NSLock()
    private var _accessToken: String?
    private var _userId: String?

    private let urlSession: URLSession

    init(serverURL: URL, deviceId: String, accessToken: String? = nil, userId: String? = nil) {
        self.serverURL = serverURL
        self.deviceId = deviceId
        self._accessToken = accessToken
        self._userId = userId
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: configuration)
    }

    var accessToken: String? {
        lock.lock(); defer { lock.unlock() }
        return _accessToken
    }

    var userId: String? {
        lock.lock(); defer { lock.unlock() }
        return _userId
    }

    var isAuthenticated: Bool { accessToken != nil && userId != nil }

    func adopt(accessToken: String?, userId: String?) {
        lock.lock(); defer { lock.unlock() }
        _accessToken = accessToken
        _userId = userId
    }

    private func requireUserId() throws -> String {
        guard let userId else { throw JellyfinError.notAuthenticated }
        return userId
    }

    // MARK: - Server address normalization (ported from Tuner)

    /// Turns loose input like "jellyfin.local:8096" into a usable base URL.
    /// Prepends https:// when no scheme is given, preserves an explicit http://,
    /// rejects non-HTTP schemes and hostless URLs, strips trailing slashes.
    static func normalizeServerInput(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinError.badURL }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { throw JellyfinError.badURL }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else { throw JellyfinError.badURL }
        return url
    }

    // MARK: - URL building (ported from Tuner; preserves reverse-proxy path prefixes)

    func apiURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinError.badURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw JellyfinError.badURL }
        return url
    }

    /// Server-relative paths like TranscodingUrl arrive pre-percent-encoded with their
    /// own query string, so this concatenates rather than going through URLComponents.
    func serverRelativeURL(_ path: String) throws -> URL {
        var base = serverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + suffix) else { throw JellyfinError.badURL }
        return url
    }

    func appendingAPIKeyIfMissing(to url: URL, token: String?) -> URL {
        guard let token, !token.isEmpty else { return url }
        let absolute = url.absoluteString
        let lowercased = absolute.lowercased()
        if lowercased.contains("api_key=") || lowercased.contains("apikey=") { return url }
        let separator = absolute.contains("?") ? "&" : "?"
        return URL(string: absolute + separator + "api_key=" + token) ?? url
    }

    // MARK: - Transport (ported from Tuner)

    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.model
        #endif
    }

    var authorizationHeader: String {
        var value = "MediaBrowser Client=\"Vlinder\", Device=\"\(Self.deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token = accessToken, !token.isEmpty {
            value += ", Token=\"\(token)\""
        }
        return value
    }

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    @discardableResult
    func send(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<Int>.none
    ) async throws -> Data {
        let url = try apiURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        // Older servers and some proxies only honor the legacy header.
        if let token = accessToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JellyfinJSON.encoder.encode(body)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            throw JellyfinError.http(status: http.statusCode, body: snippet)
        }
        return data
    }

    func sendDecoding<T: Decodable>(
        _ type: T.Type = T.self,
        method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<Int>.none,
        endpoint: String
    ) async throws -> T {
        let data = try await send(method, path: path, query: query, body: body)
        do {
            return try JellyfinJSON.decoder.decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding("\(endpoint): \(JellyfinJSON.describe(error))")
        }
    }

    // MARK: - System / auth

    func publicSystemInfo() async throws -> PublicServerInfo {
        let info: PublicServerInfo = try await sendDecoding(
            method: .get, path: "/System/Info/Public", endpoint: "System/Info/Public")
        guard info.version != nil || info.serverName != nil || info.id != nil || info.productName != nil else {
            throw JellyfinError.notJellyfin
        }
        return info
    }

    func authenticateByName(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable {
            var username: String
            var pw: String
            enum CodingKeys: String, CodingKey {
                case username = "Username"
                case pw = "Pw"
            }
        }
        let result: AuthenticationResult = try await sendDecoding(
            method: .post, path: "/Users/AuthenticateByName",
            body: Body(username: username, pw: password),
            endpoint: "Users/AuthenticateByName")
        adopt(accessToken: result.accessToken, userId: result.user?.id)
        return result
    }

    // MARK: - Quick Connect (ported from Tuner, incl. pre-10.9 fallbacks)

    func quickConnectEnabled() async throws -> Bool {
        let data = try await send(.get, path: "/QuickConnect/Enabled")
        // The endpoint returns a bare JSON boolean.
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == "true"
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        do {
            return try await sendDecoding(
                method: .post, path: "/QuickConnect/Initiate", endpoint: "QuickConnect/Initiate")
        } catch JellyfinError.http(let status, _) where status == 404 || status == 405 {
            // Pre-10.9 servers expose Initiate as GET.
            return try await sendDecoding(
                method: .get, path: "/QuickConnect/Initiate", endpoint: "QuickConnect/Initiate")
        } catch JellyfinError.http(let status, _) where status == 401 {
            throw JellyfinError.quickConnectDisabled
        }
    }

    /// Polls the state of a pending Quick Connect request.
    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        do {
            return try await sendDecoding(
                method: .get, path: "/QuickConnect/Connect",
                query: [URLQueryItem(name: "secret", value: secret)],
                endpoint: "QuickConnect/Connect")
        } catch JellyfinError.http(let status, _) where status == 404 {
            throw JellyfinError.quickConnectExpired
        }
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        struct Body: Encodable {
            var secret: String
            enum CodingKeys: String, CodingKey {
                case secret = "Secret"
            }
        }
        let result: AuthenticationResult = try await sendDecoding(
            method: .post, path: "/Users/AuthenticateWithQuickConnect",
            body: Body(secret: secret),
            endpoint: "Users/AuthenticateWithQuickConnect")
        adopt(accessToken: result.accessToken, userId: result.user?.id)
        return result
    }

    func currentUser() async throws -> JellyfinUser {
        try await sendDecoding(method: .get, path: "/Users/Me", endpoint: "Users/Me")
    }

    // MARK: - Browse

    static let listFields = "PrimaryImageAspectRatio,Overview,ChildCount,RecursiveItemCount,MediaSourceCount,ParentThumbItemId,ParentBackdropItemId,ParentBackdropImageTags"

    func userViews() async throws -> [BaseItem] {
        let userId = try requireUserId()
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Users/\(userId)/Views", endpoint: "Users/Views")
        return result.items ?? []
    }

    func resumeItems(limit: Int = 20, mediaTypes: String = "Video") async throws -> [BaseItem] {
        let userId = try requireUserId()
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Users/\(userId)/Items/Resume",
            query: [
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "MediaTypes", value: mediaTypes),
                URLQueryItem(name: "Fields", value: Self.listFields),
            ],
            endpoint: "Items/Resume")
        return result.items ?? []
    }

    func nextUp(limit: Int = 20, seriesId: String? = nil) async throws -> [BaseItem] {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "EnableResumable", value: "false"),
            URLQueryItem(name: "Fields", value: Self.listFields),
        ]
        if let seriesId {
            query.append(URLQueryItem(name: "SeriesId", value: seriesId))
        }
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Shows/NextUp", query: query, endpoint: "Shows/NextUp")
        return result.items ?? []
    }

    func similar(itemId: String, limit: Int = 16) async throws -> [BaseItem] {
        let userId = try requireUserId()
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Items/\(itemId)/Similar",
            query: [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "fields", value: Self.listFields),
            ],
            endpoint: "Items/Similar")
        return result.items ?? []
    }

    func latest(parentId: String?, limit: Int = 20) async throws -> [BaseItem] {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.listFields),
        ]
        if let parentId {
            query.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        // Note: returns a bare array, not an ItemsResult envelope.
        return try await sendDecoding(
            method: .get, path: "/Users/\(userId)/Items/Latest",
            query: query, endpoint: "Items/Latest")
    }

    struct ItemsQuery {
        var parentId: String?
        var includeItemTypes: [String] = []
        var sortBy: String = "SortName"
        var sortOrder: String = "Ascending"
        var recursive: Bool = false
        var startIndex: Int = 0
        var limit: Int = 100
        var searchTerm: String?
        var filters: [String] = []
        var genres: [String] = []
        var personIds: [String] = []
        var years: [Int] = []
        var officialRatings: [String] = []
        var tags: [String] = []
    }

    func items(_ q: ItemsQuery) async throws -> ItemsResult {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "SortBy", value: q.sortBy),
            URLQueryItem(name: "SortOrder", value: q.sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(q.startIndex)"),
            URLQueryItem(name: "Limit", value: "\(q.limit)"),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        if let parentId = q.parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if q.recursive { query.append(URLQueryItem(name: "Recursive", value: "true")) }
        if !q.includeItemTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: q.includeItemTypes.joined(separator: ",")))
        }
        if let term = q.searchTerm, !term.isEmpty {
            query.append(URLQueryItem(name: "SearchTerm", value: term))
        }
        if !q.filters.isEmpty {
            query.append(URLQueryItem(name: "Filters", value: q.filters.joined(separator: ",")))
        }
        if !q.genres.isEmpty {
            query.append(URLQueryItem(name: "Genres", value: q.genres.joined(separator: "|")))
        }
        if !q.personIds.isEmpty {
            query.append(URLQueryItem(name: "PersonIds", value: q.personIds.joined(separator: ",")))
        }
        if !q.years.isEmpty {
            query.append(URLQueryItem(name: "Years", value: q.years.map(String.init).joined(separator: ",")))
        }
        if !q.officialRatings.isEmpty {
            query.append(URLQueryItem(name: "OfficialRatings", value: q.officialRatings.joined(separator: "|")))
        }
        if !q.tags.isEmpty {
            query.append(URLQueryItem(name: "Tags", value: q.tags.joined(separator: "|")))
        }
        return try await sendDecoding(
            method: .get, path: "/Users/\(userId)/Items", query: query, endpoint: "Users/Items")
    }

    func item(id: String) async throws -> BaseItem {
        let userId = try requireUserId()
        return try await sendDecoding(
            method: .get, path: "/Users/\(userId)/Items/\(id)", endpoint: "Users/Items/{id}")
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let userId = try requireUserId()
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Shows/\(seriesId)/Seasons",
            query: [
                URLQueryItem(name: "UserId", value: userId),
                URLQueryItem(name: "Fields", value: Self.listFields),
            ],
            endpoint: "Shows/Seasons")
        return result.items ?? []
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Fields", value: Self.listFields),
        ]
        if let seasonId {
            query.append(URLQueryItem(name: "SeasonId", value: seasonId))
        }
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/Shows/\(seriesId)/Episodes", query: query, endpoint: "Shows/Episodes")
        return result.items ?? []
    }

    // MARK: - User data

    func setPlayed(itemId: String, played: Bool) async throws {
        let userId = try requireUserId()
        try await send(played ? .post : .delete, path: "/Users/\(userId)/PlayedItems/\(itemId)")
    }

    func setFavorite(itemId: String, favorite: Bool) async throws {
        let userId = try requireUserId()
        try await send(favorite ? .post : .delete, path: "/Users/\(userId)/FavoriteItems/\(itemId)")
    }

    // MARK: - Live TV

    func liveTvChannels() async throws -> [BaseItem] {
        let userId = try requireUserId()
        let result: ItemsResult = try await sendDecoding(
            method: .get, path: "/LiveTv/Channels",
            query: [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "enableImages", value: "true"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "addCurrentProgram", value: "true"),
                URLQueryItem(name: "fields", value: "ChannelInfo"),
            ],
            endpoint: "LiveTv/Channels")
        return result.items ?? []
    }

    /// POST so long channel-id lists don't blow the URL length limit (Tuner pattern).
    /// With channelIds nil this pages over ALL channels' programs in the window
    /// (the Fladder fork's bulk-guide fetch, limit 800 per page).
    func programs(
        channelIds: [String]? = nil,
        from: Date,
        to: Date,
        startIndex: Int? = nil,
        limit: Int? = nil
    ) async throws -> [BaseItem] {
        var body = ProgramsRequestBody(channelIds: channelIds, minEndDate: from, maxStartDate: to)
        body.startIndex = startIndex
        body.limit = limit
        let result: ItemsResult = try await sendDecoding(
            method: .post, path: "/LiveTv/Programs", body: body, endpoint: "LiveTv/Programs")
        return result.items ?? []
    }

    func specialFeatures(itemId: String) async throws -> [BaseItem] {
        let userId = try requireUserId()
        return try await sendDecoding(
            method: .get, path: "/Items/\(itemId)/SpecialFeatures",
            query: [URLQueryItem(name: "userId", value: userId)],
            endpoint: "Items/SpecialFeatures")
    }

    /// Available filter values for a library (legacy Filters shape: plain strings).
    func filters(parentId: String?, includeItemTypes: [String]) async throws -> FilterValues {
        let userId = try requireUserId()
        var query = [URLQueryItem(name: "userId", value: userId)]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if !includeItemTypes.isEmpty {
            query.append(URLQueryItem(name: "includeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        return try await sendDecoding(
            method: .get, path: "/Items/Filters", query: query, endpoint: "Items/Filters")
    }

    // MARK: - Stream resolution

    struct ResolvedStream {
        var url: URL
        var playMethod: String // "DirectPlay" | "DirectStream" | "Transcode"
        var playSessionId: String?
        var mediaSourceId: String?
        var liveStreamId: String?
        var mediaSource: MediaSource?
        var isLive: Bool
    }

    /// Live TV stream resolution — Tuner's `startStream(channelId:)` with one
    /// AVPlayer-mandated deviation: direct play/stream are disabled in the
    /// REQUEST (profile untouched) so the server always returns an HLS
    /// TranscodingUrl. AVPlayer accepts an endless raw MPEG-TS HTTP stream,
    /// reads a few KB, and aborts before readyToPlay ("operation stopped"),
    /// so there is deliberately no stream.ts fallback for live playback.
    func startLiveStream(channelId: String) async throws -> ResolvedStream {
        let userId = try requireUserId()
        var body = PlaybackInfoBody(deviceProfile: .live, autoOpenLiveStream: true)
        body.enableDirectPlay = false
        body.enableDirectStream = false
        let info: PlaybackInfoResponse = try await sendDecoding(
            method: .post, path: "/Items/\(channelId)/PlaybackInfo",
            query: [URLQueryItem(name: "userId", value: userId)],
            body: body,
            endpoint: "PlaybackInfo(live)")
        guard let source = info.mediaSources?.first else { throw JellyfinError.noMediaSource }
        guard let transcodingPath = source.transcodingUrl, !transcodingPath.isEmpty else {
            throw JellyfinError.liveStreamUnavailable
        }
        let url = appendingAPIKeyIfMissing(to: try serverRelativeURL(transcodingPath), token: accessToken)
        #if DEBUG
        print("[Vlinder] live stream url: \(Self.redactingAPIKey(url.absoluteString))")
        print("[Vlinder] liveStreamId=\(source.liveStreamId ?? "nil") container=\(source.container ?? "nil")")
        #endif
        return ResolvedStream(
            url: url,
            playMethod: "Transcode",
            playSessionId: info.playSessionId,
            mediaSourceId: source.id,
            liveStreamId: source.liveStreamId,
            mediaSource: source,
            isLive: true)
    }

    /// Strips credential values from URLs/strings destined for logs.
    /// Matches api_key (legacy) and ApiKey (10.11 TranscodingUrl spelling).
    static func redactingAPIKey(_ string: String) -> String {
        string.replacingOccurrences(
            of: #"(?i)((?:api_key|apikey)=)[^&\s"]+"#,
            with: "$1REDACTED",
            options: .regularExpression)
    }

    /// VOD stream resolution: ask PlaybackInfo with our device profile, then prefer
    /// direct play, else the server's TranscodingUrl, else a direct-stream URL.
    func startVideoStream(
        itemId: String,
        startTimeTicks: Int64? = nil,
        mediaSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> ResolvedStream {
        let userId = try requireUserId()
        var body = PlaybackInfoBody(deviceProfile: .vod)
        body.isPlayback = true
        body.maxStreamingBitrate = 120_000_000
        body.startTimeTicks = startTimeTicks
        body.mediaSourceId = mediaSourceId
        body.audioStreamIndex = audioStreamIndex
        body.subtitleStreamIndex = subtitleStreamIndex
        let info: PlaybackInfoResponse = try await sendDecoding(
            method: .post, path: "/Items/\(itemId)/PlaybackInfo",
            query: [URLQueryItem(name: "userId", value: userId)],
            body: body,
            endpoint: "PlaybackInfo(vod)")
        guard let source = info.mediaSources?.first(where: { $0.id == mediaSourceId }) ?? info.mediaSources?.first
        else { throw JellyfinError.noMediaSource }
        #if DEBUG
        print("[Vlinder] vod source: container=\(source.container ?? "nil") directPlay=\(source.supportsDirectPlay ?? false) directStream=\(source.supportsDirectStream ?? false) transcodingUrl=\(Self.redactingAPIKey(source.transcodingUrl ?? "nil"))")
        #endif

        // Direct play only when no specific tracks were requested; AVPlayer can't
        // honor Jellyfin stream indices on a static file the way the server's
        // HLS remux can.
        let wantsSpecificTracks = subtitleStreamIndex != nil || audioStreamIndex != nil
        if source.supportsDirectPlay == true, !wantsSpecificTracks {
            var query = [URLQueryItem(name: "static", value: "true")]
            if let sourceId = source.id { query.append(URLQueryItem(name: "mediaSourceId", value: sourceId)) }
            if let etag = source.etag { query.append(URLQueryItem(name: "Tag", value: etag)) }
            if let token = accessToken { query.append(URLQueryItem(name: "api_key", value: token)) }
            let container = source.container?.components(separatedBy: ",").first ?? "mp4"
            let url = try apiURL(path: "/Videos/\(itemId)/stream.\(container)", query: query)
            return ResolvedStream(
                url: url, playMethod: "DirectPlay", playSessionId: info.playSessionId,
                mediaSourceId: source.id, liveStreamId: nil, mediaSource: source, isLive: false)
        }
        if let transcodingPath = source.transcodingUrl, !transcodingPath.isEmpty {
            let url = appendingAPIKeyIfMissing(to: try serverRelativeURL(transcodingPath), token: accessToken)
            return ResolvedStream(
                url: url, playMethod: "Transcode", playSessionId: info.playSessionId,
                mediaSourceId: source.id, liveStreamId: nil, mediaSource: source, isLive: false)
        }
        if source.supportsDirectStream == true {
            var query = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: source.id ?? itemId),
            ]
            if let token = accessToken { query.append(URLQueryItem(name: "api_key", value: token)) }
            let container = source.container?.components(separatedBy: ",").first ?? "mp4"
            let url = try apiURL(path: "/Videos/\(itemId)/stream.\(container)", query: query)
            return ResolvedStream(
                url: url, playMethod: "DirectStream", playSessionId: info.playSessionId,
                mediaSourceId: source.id, liveStreamId: nil, mediaSource: source, isLive: false)
        }
        throw JellyfinError.noMediaSource
    }

    // MARK: - Playback reporting (best-effort; never fails playback)

    func reportPlaybackStart(_ body: PlaybackStartBody) async {
        try? await send(.post, path: "/Sessions/Playing", body: body)
    }

    func reportPlaybackProgress(_ body: PlaybackProgressBody) async {
        try? await send(.post, path: "/Sessions/Playing/Progress", body: body)
    }

    func reportPlaybackStopped(_ body: PlaybackStopBody) async {
        try? await send(.post, path: "/Sessions/Playing/Stopped", body: body)
    }

    /// Frees the server-side stream consumer after live playback.
    /// Jellyfin (10.11 included) takes liveStreamId as a QUERY parameter — a
    /// JSON body returns HTTP 400 and leaks the stream on the server.
    func closeLiveStream(liveStreamId: String) async {
        try? await send(
            .post, path: "/LiveStreams/Close",
            query: [URLQueryItem(name: "liveStreamId", value: liveStreamId)])
    }

    func stopActiveEncodings(playSessionId: String?) async {
        var query = [URLQueryItem(name: "deviceId", value: deviceId)]
        if let playSessionId {
            query.append(URLQueryItem(name: "playSessionId", value: playSessionId))
        }
        try? await send(.delete, path: "/Videos/ActiveEncodings", query: query)
    }

    // MARK: - Images

    enum ImageType: String {
        case primary = "Primary"
        case backdrop = "Backdrop"
        case logo = "Logo"
        case thumb = "Thumb"
        case banner = "Banner"
    }

    /// api_key travels in the query because image views can't send headers.
    /// The tag doubles as a cache-buster; no tag → no URL (matches Tuner).
    func imageURL(
        itemId: String,
        type: ImageType = .primary,
        tag: String?,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        var query = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "\(quality)"),
        ]
        if let maxWidth { query.append(URLQueryItem(name: "maxWidth", value: "\(maxWidth)")) }
        if let maxHeight { query.append(URLQueryItem(name: "maxHeight", value: "\(maxHeight)")) }
        if let token = accessToken, !token.isEmpty {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        return try? apiURL(path: "/Items/\(itemId)/Images/\(type.rawValue)", query: query)
    }

    func chapterImageURL(itemId: String, index: Int, tag: String?, maxWidth: Int = 480) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        var query = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let token = accessToken, !token.isEmpty {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        return try? apiURL(path: "/Items/\(itemId)/Images/Chapter/\(index)", query: query)
    }

    func userImageURL(userId: String, tag: String?, size: Int = 120) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        var query = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "maxWidth", value: "\(size)"),
        ]
        if let token = accessToken, !token.isEmpty {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        return try? apiURL(path: "/UserImage", query: [URLQueryItem(name: "userId", value: userId)] + query)
    }
}
