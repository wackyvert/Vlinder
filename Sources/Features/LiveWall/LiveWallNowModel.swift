import Foundation
import Observation

/// What is on right now, fetched for the wall alone.
///
/// The flat guide loads a 16-hour window across every channel, because that is
/// what a guide is: a grid you scroll through time. The wall is not a grid — it
/// only ever shows this minute — so asking for sixteen hours of a 1200-channel
/// lineup to read one programme per channel is both far slower and far more
/// data than it needs. This asks for a couple of hours around now instead, and
/// keeps only the programme airing on each channel.
@MainActor
@Observable
final class LiveWallNowModel {
    private(set) var programs: [String: BaseItem] = [:]
    /// How many programmes the server actually returned for the window, before
    /// the airing-now filter. Distinguishes "this lineup has no guide data"
    /// from "we asked for the wrong window".
    private(set) var fetchedCount = 0
    private(set) var sampleWindow: String = "-"
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    private(set) var errorMessage: String?

    /// How far either side of now to ask for. Wide enough to catch a programme
    /// that started before the window and runs past it.
    static let lookBack: TimeInterval = 3 * 3600
    static let lookAhead: TimeInterval = 1 * 3600
    /// The wall is a picture of a moment, so it goes stale quickly.
    static let staleAfter: TimeInterval = 10 * 60

    @ObservationIgnored private var sequence = 0

    var isStale: Bool {
        guard let lastLoaded else { return true }
        return Date().timeIntervalSince(lastLoaded) > Self.staleAfter
    }

    func ensureFresh(client: JellyfinClient) async {
        guard !isLoading, isStale else { return }
        await load(client: client)
    }

    func load(client: JellyfinClient) async {
        sequence += 1
        let token = sequence
        isLoading = true
        errorMessage = nil
        defer { if token == sequence { isLoading = false } }

        let now = Date()
        let from = now.addingTimeInterval(-Self.lookBack)
        let to = now.addingTimeInterval(Self.lookAhead)

        do {
            var airing: [String: BaseItem] = [:]
            var fetched = 0
            var sample = "-"
            var startIndex = 0
            while true {
                let page = try await client.programs(
                    from: from, to: to,
                    startIndex: startIndex, limit: GuideModel.programPageSize,
                    enableImages: true)
                guard token == sequence else { return }

                fetched += page.count
                if sample == "-", let first = page.first {
                    let start = first.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                    let end = first.endDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                    sample = "\(first.name ?? "?") [\(start) → \(end)] ch=\(first.channelId ?? "nil")"
                }
                for program in page {
                    guard let channelId = program.channelId, !channelId.isEmpty,
                          let start = program.startDate, let end = program.endDate,
                          start <= now, now < end
                    else { continue }
                    airing[channelId] = program
                }

                // Show what has arrived rather than making the wall wait for
                // the last page: a card that fills in is better than a blank one.
                programs = airing
                fetchedCount = fetched
                sampleWindow = sample
                if page.count < GuideModel.programPageSize { break }
                startIndex += GuideModel.programPageSize
            }
            lastLoaded = Date()
        } catch {
            guard token == sequence else { return }
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }
    }

    func program(for channelId: String) -> BaseItem? {
        programs[channelId]
    }
}
