import XCTest

private actor TestSource: GuideDataSource {
    nonisolated let serverURL = URL(string: "https://guide.invalid")!
    nonisolated let userId: String?
    var channels: [BaseItem]
    var listings: [BaseItem]
    var channelFlags: [Bool] = []
    struct Query: Sendable {
        var ids: [String]?
        var from: Date
        var to: Date
        var start: Int
    }
    var queries: [Query] = []
    var failPrograms = false
    var channelDelay: UInt64 = 0
    var bulkDelay: UInt64 = 0

    init(user: String = "test", channels: [BaseItem], listings: [BaseItem] = []) {
        userId = user
        self.channels = channels
        self.listings = listings
    }
    func setListings(_ value: [BaseItem]) { listings = value }
    func setFailure(_ value: Bool) { failPrograms = value }
    func setDelay(_ value: UInt64) { channelDelay = value }
    func setBulkDelay(_ value: UInt64) { bulkDelay = value }
    func liveTvChannels(includeCurrentProgram: Bool) async throws -> [BaseItem] {
        channelFlags.append(includeCurrentProgram)
        if channelDelay > 0 { try await Task.sleep(nanoseconds: channelDelay) }
        return channels
    }
    func programs(channelIds: [String]?, from: Date, to: Date,
                  startIndex: Int?, limit: Int?, enableImages: Bool) async throws -> [BaseItem] {
        queries.append(Query(ids: channelIds, from: from, to: to, start: startIndex ?? 0))
        if failPrograms { throw URLError(.timedOut) }
        if channelIds == nil, bulkDelay > 0 { try await Task.sleep(nanoseconds: bulkDelay) }
        let selected = listings.filter {
            (channelIds == nil || channelIds!.contains($0.channelId ?? ""))
                && ($0.startDate ?? .distantFuture) < to
                && ($0.endDate ?? .distantPast) > from
        }.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        return Array(selected.dropFirst(startIndex ?? 0).prefix(limit ?? selected.count))
    }
}

@MainActor
final class GuidePerformanceTests: XCTestCase {
    private func makeCache() -> GuideCache {
        GuideCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-test-" + UUID().uuidString))
    }
    private func channel(_ id: String) -> BaseItem { BaseItem(id: id, name: id) }
    private func program(_ id: String, channel: String, start: Date, hours: Double) -> BaseItem {
        var item = BaseItem(id: id, name: id)
        item.channelId = channel
        item.startDate = start
        item.endDate = start.addingTimeInterval(hours * 3600)
        return item
    }

    func testFirstScreenPrecedesWholeLineupAndFutureWindow() async {
        let source = TestSource(channels: (0..<40).map { channel(String(format: "%02d", $0)) })
        let guide = GuideModel(cache: makeCache())
        await guide.ensureFresh(client: source, settings: AppSettings())
        let flags = await source.channelFlags
        let queries = await source.queries
        XCTAssertEqual(flags, [false], "Do not request Jellyfin's per-channel current program join")
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0].ids?.count, 12)
        XCTAssertEqual(queries[0].to.timeIntervalSince(queries[0].from), 2 * 3600)
        XCTAssertNil(queries[1].ids)
        XCTAssertNil(queries[2].ids)
        XCTAssertEqual(queries[2].from, queries[1].to)
        XCTAssertEqual(queries[2].to.timeIntervalSince(queries[0].from), 16 * 3600)
        XCTAssertEqual(guide.status, .loaded)
        await guide.ensureFresh(client: source, settings: AppSettings())
        let after = await source.channelFlags
        XCTAssertEqual(after.count, 1, "Returning to a fresh guide must not reload it")
    }

    func testPagingAndProgramsCrossingWindowBoundaryAreNotDuplicated() async {
        let start = GuideModel.windowStartDate()
        let items = (0..<805).map {
            program("p\($0)", channel: "c", start: start.addingTimeInterval(Double($0)), hours: 3)
        }
        let source = TestSource(channels: [channel("c")], listings: items)
        let guide = GuideModel(cache: makeCache())
        await guide.fetch(client: source, settings: AppSettings())
        XCTAssertEqual(guide.programsByChannel["c"]?.count, 805)
        let queries = await source.queries
        XCTAssertTrue(queries.contains { $0.start == 800 })
        XCTAssertEqual(Set(guide.programsByChannel["c", default: []].map(\.id)).count, 805)
    }

    func testRefreshRemovesCancelledListingsAndRetainsCrossBoundaryProgram() async {
        let start = GuideModel.windowStartDate()
        let old = program("cancelled", channel: "c", start: start, hours: 1)
        let spanning = program("spanning", channel: "c", start: start, hours: 4)
        let source = TestSource(channels: [channel("c")], listings: [old, spanning])
        let guide = GuideModel(cache: makeCache())
        await guide.fetch(client: source, settings: AppSettings())
        await source.setListings([spanning])
        await guide.fetch(client: source, settings: AppSettings())
        XCTAssertEqual(guide.programsByChannel["c"]?.map(\.id), ["spanning"])
        await source.setListings([])
        await guide.fetch(client: source, settings: AppSettings())
        XCTAssertEqual(guide.programsByChannel["c"], [])
    }

    func testCachedGuideAppearsBeforeNetworkAndFailureCanRetry() async throws {
        let cache = makeCache()
        let start = GuideModel.windowStartDate()
        let source = TestSource(channels: [channel("c")], listings: [program("p", channel: "c", start: start, hours: 1)])
        let first = GuideModel(cache: cache)
        await first.fetch(client: source, settings: AppSettings())
        await source.setDelay(200_000_000)
        await source.setFailure(true)
        let restored = GuideModel(cache: cache)
        let load = Task { await restored.ensureFresh(client: source, settings: AppSettings()) }
        for _ in 0..<100 where restored.channels.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(restored.channels.map(\.id), ["c"])
        XCTAssertEqual(restored.programsByChannel["c"]?.map(\.id), ["p"])
        XCTAssertEqual(restored.status, .loadingPrograms)
        await load.value
        XCTAssertNotNil(restored.refreshError)
        XCTAssertEqual(restored.programsByChannel["c"]?.map(\.id), ["p"])
        await source.setFailure(false)
        await restored.ensureFresh(client: source, settings: AppSettings())
        XCTAssertNil(restored.refreshError)
    }

    func testChannelListingsPublishPerChannelAndHoldWhileTheGridMoves() async {
        let start = GuideModel.windowStartDate()
        let source = TestSource(channels: [channel("a"), channel("b")])
        let guide = GuideModel(cache: makeCache())
        await guide.ensureFresh(client: source, settings: AppSettings())
        let a = guide.listings(for: "a")
        let b = guide.listings(for: "b")
        XCTAssertTrue(a === guide.listings(for: "a"), "One observable per channel, reused")
        XCTAssertEqual(a.programs, [])

        await source.setListings([program("p", channel: "a", start: start, hours: 1)])
        guide.holdListingUpdates(true)
        await guide.fetch(client: source, settings: AppSettings())
        XCTAssertEqual(guide.programsByChannel["a"]?.map(\.id), ["p"], "The model's record is never held")
        XCTAssertEqual(a.programs, [], "The screen's copy waits while the grid moves")
        guide.holdListingUpdates(false)
        XCTAssertEqual(a.programs.map(\.id), ["p"])
        XCTAssertEqual(b.programs, [], "A page for one channel leaves the others alone")
        XCTAssertEqual(a.airing(on: channel("a"), at: start.addingTimeInterval(60))?.id, "p")
    }

    func testAccountSwitchCancelsOldLoadAndNeverReusesOtherAccountsCache() async throws {
        let cache = makeCache()
        let a = TestSource(user: "a", channels: [channel("private-a")])
        await a.setDelay(100_000_000)
        let b = TestSource(user: "b", channels: [channel("private-b")])
        let guide = GuideModel(cache: cache)
        let old = Task { await guide.ensureFresh(client: a, settings: AppSettings()) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await guide.ensureFresh(client: b, settings: AppSettings())
        await old.value
        XCTAssertEqual(guide.channels.map(\.id), ["private-b"])
        let other = await cache.load(identity: "https://guide.invalid|a", now: Date())
        XCTAssertNil(other)
    }

    func testViewCancellationDoesNotCancelSharedLoad() async throws {
        let source = TestSource(channels: [channel("c")])
        await source.setDelay(50_000_000)
        let guide = GuideModel(cache: makeCache())
        let first = Task { await guide.ensureFresh(client: source, settings: AppSettings()) }
        try await Task.sleep(nanoseconds: 5_000_000)
        first.cancel()
        await guide.ensureFresh(client: source, settings: AppSettings())
        XCTAssertEqual(guide.status, .loaded)
        let flags = await source.channelFlags
        XCTAssertEqual(flags.count, 1)
    }

    func testVisibleFutureListingsDoNotWaitForBackgroundAndAreNotFetchedTwice() async throws {
        let source = TestSource(channels: [channel("c")])
        await source.setBulkDelay(150_000_000)
        let guide = GuideModel(cache: makeCache())
        let background = Task { await guide.ensureFresh(client: source, settings: AppSettings()) }
        for _ in 0..<100 {
            if await source.queries.count >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let from = guide.windowStart.addingTimeInterval(4 * 3600)
        let to = from.addingTimeInterval(2 * 3600)
        await guide.loadVisiblePrograms(client: source, channelIds: ["c"], from: from, to: to)
        XCTAssertEqual(guide.status, .loadingPrograms)
        await guide.loadVisiblePrograms(client: source, channelIds: ["c"], from: from, to: to)
        let visible = await source.queries.filter { $0.ids == ["c"] && $0.from == from }
        XCTAssertEqual(visible.count, 1, "Even empty channels have coverage; do not refetch on each scroll")
        await background.value
        XCTAssertEqual(guide.status, .loaded)
    }

    func testViewportBoundsArtworkAndPreservesMixedRowGeometry() {
        let heights: [CGFloat] = [38] + Array(repeating: 120, count: 1000)
        let viewport = GuideViewport(heights: heights, offset: 6000, height: 600, buffer: 360)
        XCTAssertLessThanOrEqual(viewport.range.count, 12)
        XCTAssertEqual(viewport.top + heights[viewport.range].reduce(0, +) + viewport.bottom,
                       heights.reduce(0, +))
        XCTAssertLessThanOrEqual(viewport.top, 6000 - 360)
        let empty = GuideViewport(heights: [], offset: 0, height: 600, buffer: 360)
        XCTAssertTrue(empty.range.isEmpty)
        let overscrolled = GuideViewport(heights: [38, 120], offset: 5000, height: 600, buffer: 360)
        XCTAssertTrue(overscrolled.range.isEmpty)
        XCTAssertEqual(overscrolled.top, 158)
    }

    func testCacheRejectsExpiredAndFutureSnapshots() async {
        let cache = makeCache()
        let now = Date()
        var snapshot = GuideCache.Snapshot(savedAt: now, windowStart: now.addingTimeInterval(-1800),
            windowEnd: now.addingTimeInterval(3600), channels: [channel("c")], programs: [:])
        await cache.save(snapshot, identity: "one")
        let valid = await cache.load(identity: "one", now: now)
        let wrongAccount = await cache.load(identity: "two", now: now)
        XCTAssertNotNil(valid)
        XCTAssertNil(wrongAccount)
        snapshot.windowEnd = now
        XCTAssertFalse(snapshot.isUsable(at: now))
        snapshot.windowEnd = now.addingTimeInterval(16 * 3600)
        snapshot.savedAt = now.addingTimeInterval(-25 * 3600)
        XCTAssertFalse(snapshot.isUsable(at: now))
        snapshot.savedAt = now.addingTimeInterval(3600)
        XCTAssertFalse(snapshot.isUsable(at: now))
    }
}
