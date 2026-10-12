import Foundation
import Observation

/// The Atrium's way down into a show: the library shelf opens a series onto a
/// shelf of its seasons, and a season onto a shelf of its episodes, without
/// ever leaving the room.
///
/// The library shelf itself is not owned here — it stays the paged
/// `LibraryGridModel` the poster grid also uses, so switching presentations
/// never refetches. This owns only what hangs below it, and the way back up.
@MainActor
@Observable
final class AtriumBrowseModel {
    /// One shelf below the library.
    struct Level: Identifiable, Equatable {
        enum Kind { case seasons, episodes }

        /// The item that was opened to reach this shelf.
        let container: BaseItem
        /// What the breadcrumb calls it.
        let title: String
        /// Which case the shelf above was left on, so backing out returns to it.
        let parentFocusIndex: Int

        /// Settles once the shelf loads: a show with a single season opens
        /// straight onto its episodes.
        var kind: Kind
        var items: [BaseItem] = []
        var isLoading = true
        var errorMessage: String?

        var id: String { container.id }
    }

    private(set) var levels: [Level] = []
    /// Left behind by a pop: the case the viewer was on before they went down.
    private(set) var pendingFocusIndex: Int?

    /// Strands the results of loads whose shelf has since been put away.
    private var sequence = 0

    var current: Level? { levels.last }
    var isAtRoot: Bool { levels.isEmpty }

    /// The path so far, the library shelf first.
    func breadcrumb(root: String) -> [String] {
        [root] + levels.map(\.title)
    }

    // MARK: - Going down

    func descend(into item: BaseItem, from focusIndex: Int, client: JellyfinClient) {
        guard item.atriumOpensAShelf else { return }
        levels.append(Level(
            container: item,
            title: item.displayTitle,
            parentFocusIndex: focusIndex,
            kind: item.type == .season ? .episodes : .seasons))
        pendingFocusIndex = nil
        load(client: client)
    }

    func retry(client: JellyfinClient) {
        guard !levels.isEmpty else { return }
        levels[levels.count - 1].errorMessage = nil
        levels[levels.count - 1].isLoading = true
        load(client: client)
    }

    private func load(client: JellyfinClient) {
        guard let level = levels.last else { return }
        sequence += 1
        let token = sequence
        let depth = levels.count
        let container = level.container
        Task {
            do {
                let shelf = try await Self.shelf(under: container, client: client)
                guard accepts(token: token, depth: depth) else { return }
                levels[depth - 1].kind = shelf.kind
                levels[depth - 1].items = shelf.items
                levels[depth - 1].isLoading = false
            } catch {
                guard accepts(token: token, depth: depth) else { return }
                if !error.isCancellation {
                    levels[depth - 1].errorMessage = error.localizedDescription
                }
                levels[depth - 1].isLoading = false
            }
        }
    }

    /// A result is only wanted if it is still the newest ask for the shelf that
    /// is still standing at that depth.
    private func accepts(token: Int, depth: Int) -> Bool {
        token == sequence && levels.count == depth
    }

    /// What hangs under an item. A show with a single season opens straight
    /// onto its episodes — a shelf holding one case is a dead end, not a
    /// choice — and a show with no season folders at all lists its episodes
    /// flat rather than showing nothing.
    private static func shelf(
        under container: BaseItem,
        client: JellyfinClient
    ) async throws -> (kind: Level.Kind, items: [BaseItem]) {
        if container.type == .season {
            let seriesId = container.seriesId ?? container.parentId ?? container.id
            return (.episodes, try await client.episodes(
                seriesId: seriesId, seasonId: container.id))
        }
        let seasons = try await client.seasons(seriesId: container.id)
        if seasons.count == 1 {
            return (.episodes, try await client.episodes(
                seriesId: container.id, seasonId: seasons[0].id))
        }
        if seasons.isEmpty {
            return (.episodes, try await client.episodes(
                seriesId: container.id, seasonId: nil))
        }
        return (.seasons, seasons)
    }

    // MARK: - Coming back up

    /// Puts the current shelf away and returns to the one above it.
    @discardableResult
    func pop() -> Bool {
        guard let level = levels.popLast() else { return false }
        pendingFocusIndex = level.parentFocusIndex
        sequence += 1
        return true
    }

    /// Returns to a shelf already in the path — depth 0 being the library.
    func pop(toDepth depth: Int) {
        guard depth >= 0, depth < levels.count else { return }
        pendingFocusIndex = levels[depth].parentFocusIndex
        levels.removeSubrange(depth...)
        sequence += 1
    }

    /// Read once, by the view, after it has mounted the shelf being returned to.
    func takePendingFocus() -> Int? {
        defer { pendingFocusIndex = nil }
        return pendingFocusIndex
    }
}
