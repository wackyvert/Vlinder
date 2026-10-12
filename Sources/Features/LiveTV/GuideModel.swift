import Foundation
import Observation
import OSLog

protocol GuideDataSource: Sendable {
    var serverURL: URL { get }
    var userId: String? { get }
    func liveTvChannels(includeCurrentProgram: Bool) async throws -> [BaseItem]
    func programs(channelIds: [String]?, from: Date, to: Date,
                  startIndex: Int?, limit: Int?, enableImages: Bool) async throws -> [BaseItem]
}

extension JellyfinClient: GuideDataSource {}

/// Shows cached listings immediately, fetches the first screen next, then fills
/// the current two hours and remaining day in the background.
@MainActor
@Observable
final class GuideModel {
    enum Status: Equatable {
        case idle
        case loadingChannels
        case loadingPrograms
        case loaded
        case error(String)

        var busy: Bool { self == .loadingChannels || self == .loadingPrograms }
    }

    static let programPageSize = 800

    private(set) var channels: [BaseItem] = [] { didSet { rowCache = nil } }
    private(set) var programsByChannel: [String: [BaseItem]] = [:]
    private(set) var windowStart: Date = GuideModel.windowStartDate()
    private(set) var windowEnd: Date = GuideModel.windowStartDate().addingTimeInterval(16 * 3600)
    private(set) var status: Status = .idle
    private(set) var lineup: ChannelLineup? { didSet { rowCache = nil } }

    private(set) var refreshError: String?
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var lastSuccessfulRefresh: Date?
    @ObservationIgnored private var fetchSequence = 0
    @ObservationIgnored private var coverage: [String: [DateInterval]] = [:]
    @ObservationIgnored private let cache: GuideCache
    @ObservationIgnored private static let logger = Logger(subsystem: "dev.jake.vlinder", category: "GuidePerformance")

    init(cache: GuideCache = .shared) { self.cache = cache }

    private static func identity(for client: any GuideDataSource) -> String {
        client.serverURL.absoluteString + "|" + (client.userId ?? "")
    }
    /// The in-flight load, owned by the model rather than by whichever view
    /// happened to start it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let lineupLoader = LineupLoader.shared

    /// Previous half-hour boundary — see GuideClock.windowStart.
    static func windowStartDate() -> Date {
        GuideClock.windowStart()
    }

    /// A model-owned task survives view switches; all callers share the load.
    func ensureFresh(client: any GuideDataSource, settings: AppSettings) async {
        prepareAccount(client)
        if let loadTask {
            await loadTask.value
            return
        }
        let stale = GuideClock.now.timeIntervalSince(windowStart) > 45 * 60
        if status == .loaded, lastSuccessfulRefresh != nil, !stale { return }
        await fetch(client: client, settings: settings)
    }

    private func prepareAccount(_ client: any GuideDataSource) {
        let next = Self.identity(for: client)
        guard identity != next else { return }
        loadTask?.cancel()
        loadTask = nil
        fetchSequence += 1
        identity = next
        channels = []
        programsByChannel = [:]
        publishAllListings()
        lineup = nil
        status = .idle
        refreshError = nil
        lastSuccessfulRefresh = nil
    }

    /// Manual refresh replaces the in-flight load without blanking usable rows.
    func fetch(client: any GuideDataSource, settings: AppSettings) async {
        prepareAccount(client)
        loadTask?.cancel()
        fetchSequence += 1
        let sequence = fetchSequence
        coverage = [:]
        let task = Task { [weak self] () -> Void in
            await self?.performFetch(client: client, settings: settings, sequence: sequence)
        }
        loadTask = task
        await task.value
        if fetchSequence == sequence { loadTask = nil }
    }

    private func performFetch(client: any GuideDataSource, settings: AppSettings, sequence: Int) async {
        let started = ContinuousClock.now
        let account = Self.identity(for: client)
        refreshError = nil
        lastSuccessfulRefresh = nil
        if channels.isEmpty {
            status = .loadingChannels
            if let saved = await cache.load(identity: account, now: GuideClock.now) {
                guard sequence == fetchSequence else { return }
                channels = saved.channels
                programsByChannel = saved.programs
                publishAllListings()
                windowStart = saved.windowStart
                windowEnd = saved.windowEnd
                status = .loadingPrograms
                Self.logger.info("Cache displayed after \(String(describing: started.duration(to: .now)), privacy: .public)")
            }
        } else {
            status = .loadingPrograms
        }
        guard sequence == fetchSequence else { return }
        if lineup == nil { lineup = lineupLoader.cached(urlString: settings.lineupUrl) }
        async let lineupTask: Int? = refreshLineup(urlString: settings.lineupUrl, force: false)

        do {
            let fetched = try await client.liveTvChannels(includeCurrentProgram: false)
            try Task.checkCancellation()
            guard sequence == fetchSequence else { return }
            channels = Self.sortChannels(fetched)
            let ids = Set(channels.map(\.id))
            programsByChannel = programsByChannel.filter { ids.contains($0.key) }
            publishAllListings()
            windowStart = Self.windowStartDate()
            windowEnd = windowStart.addingTimeInterval(16 * 3600)
            status = channels.isEmpty ? .loaded : .loadingPrograms
            Self.logger.info("Channels displayed: \(fetched.count) after \(String(describing: started.duration(to: .now)), privacy: .public)")

            if !channels.isEmpty {
                // This uses the same group order/collapse state as the screen.
                let firstScreen = rows(collapsedGroups: settings.collapsedGroups,
                                       searchTerm: "", playingChannelId: nil)
                    .compactMap { row -> String? in
                        if case .channel(let channel) = row { return channel.id }
                        return nil
                    }.prefix(12)
                let nearEnd = windowStart.addingTimeInterval(2 * 3600)
                if !firstScreen.isEmpty {
                    try await fetchPrograms(client: client, channelIds: Array(firstScreen),
                                            from: windowStart, to: nearEnd, sequence: sequence)
                    Self.logger.info("First screen loaded after \(String(describing: started.duration(to: .now)), privacy: .public)")
                }
                try await fetchPrograms(client: client, channelIds: nil,
                                        from: windowStart, to: nearEnd, sequence: sequence)
                guard sequence == fetchSequence else { return }
                await saveCache(account: account)
                Self.logger.info("Current listings loaded after \(String(describing: started.duration(to: .now)), privacy: .public)")
                try await fetchPrograms(client: client, channelIds: nil,
                                        from: nearEnd, to: windowEnd, sequence: sequence)
            }
            guard sequence == fetchSequence else { return }
            status = .loaded
            lastSuccessfulRefresh = GuideClock.now
            await saveCache(account: account)
            Self.logger.info("Full guide loaded after \(String(describing: started.duration(to: .now)), privacy: .public)")
        } catch {
            guard sequence == fetchSequence else { return }
            if error is CancellationError {
                status = channels.isEmpty ? .idle : .loaded
            } else {
                refreshError = error.localizedDescription
                status = channels.isEmpty ? .error(error.localizedDescription) : .loaded
                Self.logger.error("Guide refresh failed; keeping available listings")
            }
        }
        _ = await lineupTask
    }

    private func saveCache(account: String) async {
        let snapshot = GuideCache.Snapshot(savedAt: GuideClock.now,
            windowStart: windowStart, windowEnd: windowEnd,
            channels: channels, programs: programsByChannel)
        await cache.save(snapshot, identity: account)
    }

    /// Numeric channel number ascending, non-numeric after, name tiebreak
    /// (the fork's _sortChannels).
    static func sortChannels(_ channels: [BaseItem]) -> [BaseItem] {
        channels.sorted { a, b in
            let numA = a.displayChannelNumber.flatMap(Double.init)
            let numB = b.displayChannelNumber.flatMap(Double.init)
            if let numA, let numB, numA != numB { return numA < numB }
            if numA != nil && numB == nil { return true }
            if numA == nil && numB != nil { return false }
            return (a.name ?? "").lowercased() < (b.name ?? "").lowercased()
        }
    }

    /// Merge pages without clearing the previous guide. On completion, remove
    /// cancelled/changed listings in this query's interval, including empty channels.
    private func fetchPrograms(client: any GuideDataSource, channelIds: [String]?,
                               from: Date, to: Date, sequence: Int) async throws {
        var fetched: [String: [String: BaseItem]] = [:]
        var startIndex = 0
        while true {
            try Task.checkCancellation()
            guard sequence == fetchSequence else { throw CancellationError() }
            let page = try await client.programs(channelIds: channelIds, from: from, to: to,
                startIndex: startIndex, limit: Self.programPageSize, enableImages: true)
            try Task.checkCancellation()
            guard sequence == fetchSequence else { throw CancellationError() }
            for program in page {
                guard let channelId = program.channelId, !channelId.isEmpty else { continue }
                fetched[channelId, default: [:]][program.id] = program
            }
            for (channel, programs) in Dictionary(grouping: page, by: { $0.channelId ?? "" }) {
                guard !channel.isEmpty else { continue }
                var merged = Dictionary(programsByChannel[channel, default: []].map { ($0.id, $0) },
                                        uniquingKeysWith: { _, new in new })
                for program in programs { merged[program.id] = program }
                programsByChannel[channel] = Self.sortedPrograms(Array(merged.values))
                publishListings(for: channel)
            }
            if page.count < Self.programPageSize { break }
            startIndex += Self.programPageSize
        }
        let queried = channelIds ?? channels.map(\.id)
        for channel in queried {
            let fresh = fetched[channel, default: [:]]
            let retained = programsByChannel[channel, default: []].filter { program in
                guard let start = program.startDate, let end = program.endDate else { return false }
                return (end <= from || start >= to) && fresh[program.id] == nil
                    && end > windowStart && start < windowEnd
            }
            programsByChannel[channel] = Self.sortedPrograms(retained + Array(fresh.values))
            publishListings(for: channel)
            coverage[channel, default: []].append(DateInterval(start: from, end: to))
        }
    }

    /// A scroll can jump ahead of background loading. The view owns this
    /// cancellable request, so fast scrolling cannot queue an unbounded backlog.
    func loadVisiblePrograms(client: any GuideDataSource, channelIds: [String],
                             from: Date, to: Date) async {
        guard identity == Self.identity(for: client), status == .loadingPrograms else { return }
        let missing = channelIds.filter { id in
            !coverage[id, default: []].contains { $0.start <= from && $0.end >= to }
        }
        guard !missing.isEmpty, to > from else { return }
        let sequence = fetchSequence
        do {
            try await fetchPrograms(client: client, channelIds: missing,
                                    from: from, to: to, sequence: sequence)
        } catch {
            // Background loading and its retry banner own error reporting.
        }
    }

    private static func sortedPrograms(_ programs: [BaseItem]) -> [BaseItem] {
        programs.sorted {
            let a = $0.startDate ?? .distantPast, b = $1.startDate ?? .distantPast
            return a == b ? $0.id < $1.id : a < b
        }
    }

    @discardableResult
    func refreshLineup(urlString: String, force: Bool) async -> Int? {
        guard !urlString.isEmpty else {
            lineup = nil
            return nil
        }
        if !force, lineup == nil, let cached = lineupLoader.cached(urlString: urlString) {
            lineup = cached
        }
        let sequence = fetchSequence
        let loaded = await lineupLoader.load(urlString: urlString, forceRefresh: force)
        guard sequence == fetchSequence else { return nil }
        if let loaded {
            lineup = loaded
        }
        return loaded?.groupOrder.count
    }

    @ObservationIgnored private var rowCache: (collapsed: [String], playing: String?, rows: [Row])?

    // MARK: - Row derivation

    enum Row: Identifiable {
        case header(group: String, count: Int, collapsed: Bool)
        case channel(BaseItem)

        var id: String {
            switch self {
            case .header(let group, _, _): "header-\(group)"
            case .channel(let channel): "channel-\(channel.id)"
            }
        }

        var height: CGFloat {
            switch self {
            case .header: GuideMetrics.groupHeaderHeight
            case .channel: GuideMetrics.rowPitch
            }
        }
    }

    static let otherGroupName = "Other Channels"

    /// Flattened guide rows: lineup groups in source order (collapsible), an
    /// "Other Channels" bucket for unmatched channels, flat list when there is
    /// no lineup. Searching ignores collapse; the playing channel's group is
    /// always expanded.
    func rows(collapsedGroups: [String], searchTerm: String, playingChannelId: String?) -> [Row] {
        let term = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        // Read the observable inputs even on a cache hit so the view remains
        // subscribed. Scrolling must not regroup and sort the entire lineup.
        let sourceChannels = channels
        let sourceLineup = lineup
        if term.isEmpty, let cached = rowCache,
           cached.collapsed == collapsedGroups, cached.playing == playingChannelId {
            return cached.rows
        }
        let visibleChannels = term.isEmpty ? sourceChannels : sourceChannels.filter { matches($0, term: term) }

        guard let lineup = sourceLineup, !lineup.isEmpty else {
            return visibleChannels.map { .channel($0) }
        }

        var grouped: [String: [BaseItem]] = [:]
        var others: [BaseItem] = []
        for channel in visibleChannels {
            let group = lineup.group(forNumber: channel.displayChannelNumber, name: channel.name ?? "")
            if let group {
                grouped[group, default: []].append(channel)
            } else {
                others.append(channel)
            }
        }

        let searching = !term.isEmpty
        var rows: [Row] = []
        for group in lineup.groupOrder {
            guard var members = grouped[group], !members.isEmpty else { continue }
            // Present channels in the provider's own order within the group.
            members.sort { a, b in
                let orderA = lineup.order(forNumber: a.displayChannelNumber, name: a.name ?? "") ?? Int.max
                let orderB = lineup.order(forNumber: b.displayChannelNumber, name: b.name ?? "") ?? Int.max
                if orderA != orderB { return orderA < orderB }
                return (a.name ?? "") < (b.name ?? "")
            }
            let containsPlaying = playingChannelId.map { id in members.contains { $0.id == id } } ?? false
            let collapsed = collapsedGroups.contains(group) && !searching && !containsPlaying
            rows.append(.header(group: group, count: members.count, collapsed: collapsed))
            if !collapsed {
                rows.append(contentsOf: members.map { .channel($0) })
            }
        }
        if !others.isEmpty {
            let group = Self.otherGroupName
            let containsPlaying = playingChannelId.map { id in others.contains { $0.id == id } } ?? false
            let collapsed = collapsedGroups.contains(group) && !searching && !containsPlaying
            rows.append(.header(group: group, count: others.count, collapsed: collapsed))
            if !collapsed {
                rows.append(contentsOf: others.map { .channel($0) })
            }
        }
        if term.isEmpty { rowCache = (collapsedGroups, playingChannelId, rows) }
        return rows
    }

    private func matches(_ channel: BaseItem, term: String) -> Bool {
        if channel.displayTitle.lowercased().contains(term) { return true }
        if channel.displayChannelNumber?.contains(term) == true { return true }
        let now = GuideClock.now
        if let programs = programsByChannel[channel.id],
           let airing = programs.first(where: { p in
               guard let start = p.startDate, let end = p.endDate else { return false }
               return start <= now && now < end
           }),
           airing.name?.lowercased().contains(term) == true {
            return true
        }
        if let current = channel.currentProgram?.value.name?.lowercased(), current.contains(term) {
            return true
        }
        return false
    }

    #if DEBUG
    /// Load the pinned fixture instead of talking to the server, so a
    /// screenshot run produces the same frame every time.
    func loadFixture() {
        fetchSequence += 1
        channels = GuideFixture.decodedChannels()
        programsByChannel = GuideFixture.decodedPrograms()
        let stressCount = min(UserDefaults.standard.integer(forKey: "GuideStressChannels"), 2000)
        if stressCount > channels.count, !channels.isEmpty {
            let originals = channels
            let originalPrograms = programsByChannel
            channels = (0..<stressCount).map { index in
                var channel = originals[index % originals.count]
                let originalId = channel.id
                channel.id = "stress-\(index)"
                programsByChannel[channel.id] = originalPrograms[originalId, default: []].map { original in
                    var program = original
                    program.id = "stress-\(index)-\(original.id)"
                    program.channelId = channel.id
                    return program
                }
                return channel
            }
        }
        publishAllListings()
        windowStart = GuideFixture.windowStart
        windowEnd = windowStart.addingTimeInterval(16 * 3600)
        lineup = nil
        status = .loaded
        FileHandle.standardError.write(Data(
            "guide-fixture: \(channels.count) channels, \(programsByChannel.values.reduce(0) { $0 + $1.count }) programs, window \(windowStart)\n".utf8))
    }
    #endif

    // MARK: - Per-channel listings

    /// Each channel's listings as an observable of its own, so a page of
    /// programmes landing for one channel rebuilds that channel's row and no
    /// other.
    ///
    /// `programsByChannel` is one property: any write to it invalidated every
    /// view that had read any channel out of it — under the guide's old body,
    /// the whole screen, once per page of a background load that runs for tens
    /// of seconds on a large lineup. The guide's rows read these instead, and
    /// `programsByChannel` stays the model's own record of what it holds.
    @ObservationIgnored private var listingsByChannel: [String: GuideListings] = [:]
    /// Channels whose published listings are behind `programsByChannel`
    /// because they changed while the grid was moving.
    @ObservationIgnored private var heldChannels: Set<String> = []
    @ObservationIgnored private var holdStarted: Date?
    @ObservationIgnored private var holdExpiry: Task<Void, Never>?
    /// A hold older than this publishes regardless, so a scroll phase that
    /// never reports idle cannot strand the guide on stale rows.
    private static let maxHold: TimeInterval = 1.5

    /// One channel's live listings. A view that reads `programs` from it is
    /// subscribed to that channel alone.
    func listings(for channelId: String) -> GuideListings {
        if let existing = listingsByChannel[channelId] { return existing }
        let made = GuideListings(programs: programsByChannel[channelId] ?? [])
        listingsByChannel[channelId] = made
        return made
    }

    /// Hold listing changes back from the screen while the grid moves.
    ///
    /// A lane re-laying-out under a moving finger costs a frame for a change
    /// nobody can read mid-scroll. Held changes land as soon as it settles.
    func holdListingUpdates(_ hold: Bool) {
        if hold {
            guard holdStarted == nil else { return }
            holdStarted = Date()
            // Lands what was held once the cap passes, even if no further
            // write arrives to do it — a guide closed mid-scroll included.
            holdExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.maxHold)) } catch { return }
                self?.flushHeldListings()
            }
        } else {
            holdStarted = nil
            holdExpiry?.cancel()
            holdExpiry = nil
            flushHeldListings()
        }
    }

    private var isHoldingListings: Bool {
        guard let holdStarted else { return false }
        return Date().timeIntervalSince(holdStarted) < Self.maxHold
    }

    private func publishListings(for channelId: String) {
        guard listingsByChannel[channelId] != nil else { return }
        if isHoldingListings {
            heldChannels.insert(channelId)
            return
        }
        flushHeldListings()
        applyListings(for: channelId)
    }

    private func publishAllListings() {
        for id in listingsByChannel.keys { publishListings(for: id) }
    }

    private func flushHeldListings() {
        guard !heldChannels.isEmpty else { return }
        let held = heldChannels
        heldChannels = []
        for id in held { applyListings(for: id) }
    }

    private func applyListings(for channelId: String) {
        guard let listings = listingsByChannel[channelId] else { return }
        let programs = programsByChannel[channelId] ?? []
        if listings.programs != programs { listings.programs = programs }
    }

    /// The program airing now on a channel (guide data first, channel payload fallback).
    func airingNow(on channel: BaseItem) -> BaseItem? {
        let now = GuideClock.now
        if let programs = programsByChannel[channel.id] {
            if let airing = programs.first(where: { p in
                guard let start = p.startDate, let end = p.endDate else { return false }
                return start <= now && now < end
            }) {
                return airing
            }
        }
        return channel.currentProgram?.value
    }
}

/// One channel's listings; see `GuideModel.listings(for:)`.
@MainActor
@Observable
final class GuideListings {
    fileprivate(set) var programs: [BaseItem]

    init(programs: [BaseItem]) {
        self.programs = programs
    }

    /// What is airing on `channel` at `date`: these listings first, then the
    /// channel payload's own current programme — `GuideModel.airingNow(on:)`
    /// for one channel, without reading the whole lineup's listings.
    func airing(on channel: BaseItem, at date: Date) -> BaseItem? {
        programs.first { program in
            guard let start = program.startDate, let end = program.endDate else { return false }
            return start <= date && date < end
        } ?? channel.currentProgram?.value
    }
}
