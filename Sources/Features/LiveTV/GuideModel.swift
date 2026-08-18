import Foundation
import Observation

/// TV guide state: the 16-hour program window, bulk-paged program loading, and
/// lineup-based channel grouping. Semantics ported from the Fladder fork's
/// live_tv_provider.dart (window math, page size 800, incremental page apply,
/// 45-minute staleness, fetch-sequence race guard).
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

    private(set) var channels: [BaseItem] = []
    private(set) var programsByChannel: [String: [BaseItem]] = [:]
    private(set) var windowStart: Date = GuideModel.windowStartDate()
    private(set) var windowEnd: Date = GuideModel.windowStartDate().addingTimeInterval(16 * 3600)
    private(set) var status: Status = .idle
    private(set) var lineup: ChannelLineup?

    @ObservationIgnored private var fetchSequence = 0
    @ObservationIgnored private let lineupLoader = LineupLoader.shared

    /// Current 15-minute boundary minus 15 minutes (Fladder fork's window start).
    static func windowStartDate() -> Date {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutesSinceMidnight = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let roundedTo15 = (minutesSinceMidnight / 15) * 15
        return calendar.startOfDay(for: now).addingTimeInterval(TimeInterval((roundedTo15 - 15) * 60))
    }

    /// Refreshes if never loaded, previously failed, or the window start has
    /// drifted more than 45 minutes into the past.
    func ensureFresh(client: JellyfinClient, settings: AppSettings) async {
        if status.busy { return }
        let stale = Date().timeIntervalSince(windowStart) > 45 * 60
        if status == .loaded && !stale {
            await refreshLineup(urlString: settings.lineupUrl, force: false)
            return
        }
        await fetch(client: client, settings: settings)
    }

    func fetch(client: JellyfinClient, settings: AppSettings) async {
        fetchSequence += 1
        let sequence = fetchSequence
        status = .loadingChannels

        async let lineupTask: Int? = refreshLineup(urlString: settings.lineupUrl, force: false)

        do {
            let fetched = try await client.liveTvChannels()
            guard sequence == fetchSequence else { return }

            channels = Self.sortChannels(fetched)
            windowStart = Self.windowStartDate()
            windowEnd = windowStart.addingTimeInterval(16 * 3600)
            programsByChannel = [:]
            status = channels.isEmpty ? .loaded : .loadingPrograms

            if !channels.isEmpty {
                try await fetchAllPrograms(client: client, sequence: sequence)
            }
        } catch {
            guard sequence == fetchSequence else { return }
            // Keep whatever data is already shown; only surface the error state
            // when there is nothing to show.
            status = channels.isEmpty ? .error(error.localizedDescription) : .loaded
        }
        _ = await lineupTask
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

    /// Loads programs for the whole window in paged bulk requests instead of
    /// one request per channel row, applying each page as it arrives.
    private func fetchAllPrograms(client: JellyfinClient, sequence: Int) async throws {
        var accumulated: [String: [BaseItem]] = [:]
        var startIndex = 0
        while true {
            let page = try await client.programs(
                from: windowStart, to: windowEnd,
                startIndex: startIndex, limit: Self.programPageSize)
            guard sequence == fetchSequence else { return }

            for program in page {
                guard let channelId = program.channelId, !channelId.isEmpty else { continue }
                accumulated[channelId, default: []].append(program)
            }

            let done = page.count < Self.programPageSize
            programsByChannel = accumulated
            if done {
                status = .loaded
                break
            }
            startIndex += Self.programPageSize
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
        let loaded = await lineupLoader.load(urlString: urlString, forceRefresh: force)
        if let loaded {
            lineup = loaded
        }
        return loaded?.groupOrder.count
    }

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
            case .channel: GuideMetrics.rowHeight
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
        let visibleChannels = term.isEmpty ? channels : channels.filter { matches($0, term: term) }

        guard let lineup, !lineup.isEmpty else {
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
        return rows
    }

    private func matches(_ channel: BaseItem, term: String) -> Bool {
        if channel.displayTitle.lowercased().contains(term) { return true }
        if channel.displayChannelNumber?.contains(term) == true { return true }
        let now = Date()
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

    /// The program airing now on a channel (guide data first, channel payload fallback).
    func airingNow(on channel: BaseItem) -> BaseItem? {
        let now = Date()
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

enum GuideMetrics {
    static let rowHeight: CGFloat = 64
    static let groupHeaderHeight: CGFloat = 38
    static let timelineHeight: CGFloat = 30
    static let widthPerMinute: CGFloat = 8
    static func leftColumnWidth(compact: Bool) -> CGFloat { compact ? 122 : 172 }
}
