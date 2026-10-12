import Foundation
import Observation

/// Paged, sortable item state for a library view, folder, box set, or person —
/// shared by the poster grid and the Atrium spatial mode so switching views
/// never refetches or forks sort/filter/pagination state.
@MainActor
@Observable
final class LibraryGridModel {
    enum Sort: String, CaseIterable, Identifiable {
        case name = "SortName"
        case dateAdded = "DateCreated"
        case releaseDate = "PremiereDate,SortName"
        case rating = "CommunityRating,SortName"
        case runtime = "Runtime,SortName"
        case random = "Random"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .releaseDate: "Release Date"
            case .rating: "Community Rating"
            case .runtime: "Runtime"
            case .random: "Random"
            }
        }
    }

    let container: BaseItem
    var sort: Sort = .name
    var ascending = true
    var favoritesOnly = false
    var unplayedOnly = false
    var selectedGenres: Set<String> = []
    var selectedYears: Set<Int> = []
    var selectedRatings: Set<String> = []
    var selectedTags: Set<String> = []

    private(set) var items: [BaseItem] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    private(set) var availableFilters: FilterValues?

    var activeFilterCount: Int {
        (favoritesOnly ? 1 : 0) + (unplayedOnly ? 1 : 0)
            + selectedGenres.count + selectedYears.count
            + selectedRatings.count + selectedTags.count
    }

    func clearFilters() {
        favoritesOnly = false
        unplayedOnly = false
        selectedGenres = []
        selectedYears = []
        selectedRatings = []
        selectedTags = []
    }

    func loadAvailableFilters(client: JellyfinClient) async {
        guard availableFilters == nil else { return }
        availableFilters = try? await client.filters(
            parentId: container.id, includeItemTypes: filterItemTypes)
    }

    private var filterItemTypes: [String] {
        includeItemTypes
    }

    private let pageSize = 100
    private var fetchSequence = 0

    init(container: BaseItem) {
        self.container = container
        // Media libraries default to newest-first feeling sorts only for dateAdded;
        // keep Fladder's default of name ascending otherwise.
        if container.collectionType == "movies" || container.collectionType == "tvshows" {
            sort = .name
        }
    }

    private var includeItemTypes: [String] {
        switch container.collectionType {
        case "movies": ["Movie"]
        case "tvshows": ["Series"]
        case "music": ["MusicAlbum"]
        case "homevideos": []
        case "boxsets": ["BoxSet"]
        default: []
        }
    }

    /// Views and tag-style containers browse recursively by type; plain folders,
    /// box sets, and playlists list direct children.
    private var browsesRecursively: Bool {
        switch container.type {
        case .userView, .collectionFolder:
            return !includeItemTypes.isEmpty || container.collectionType == "homevideos"
        default:
            return false
        }
    }

    func reload(client: JellyfinClient) async {
        fetchSequence += 1
        let sequence = fetchSequence
        isLoading = true
        errorMessage = nil
        do {
            let result = try await fetchPage(client: client, startIndex: 0)
            guard sequence == fetchSequence else { return }
            items = result.items ?? []
            total = result.totalRecordCount
            hasLoaded = true
        } catch {
            guard sequence == fetchSequence else { return }
            // A cancelled request means the view that asked for it went away;
            // that is not a failure worth showing the user.
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current item: BaseItem, client: JellyfinClient) {
        guard !isLoading,
              let total, items.count < total,
              let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 20
        else { return }
        fetchSequence += 1
        let sequence = fetchSequence
        isLoading = true
        Task {
            do {
                let result = try await fetchPage(client: client, startIndex: items.count)
                guard sequence == fetchSequence else { return }
                items.append(contentsOf: result.items ?? [])
                self.total = result.totalRecordCount ?? self.total
            } catch {
                // Silent: scrolling further retriggers the page.
            }
            if sequence == fetchSequence {
                isLoading = false
            }
        }
    }

    private func fetchPage(client: JellyfinClient, startIndex: Int) async throws -> ItemsResult {
        var query = JellyfinClient.ItemsQuery()
        query.parentId = container.id
        query.includeItemTypes = includeItemTypes
        query.recursive = browsesRecursively
        query.sortBy = sort.rawValue
        query.sortOrder = effectiveOrder
        query.startIndex = startIndex
        query.limit = pageSize
        var filters: [String] = []
        if favoritesOnly { filters.append("IsFavorite") }
        if unplayedOnly { filters.append("IsUnplayed") }
        query.filters = filters
        query.genres = Array(selectedGenres)
        query.years = Array(selectedYears)
        query.officialRatings = Array(selectedRatings)
        query.tags = Array(selectedTags)
        return try await client.items(query)
    }

    private var effectiveOrder: String {
        ascending ? "Ascending" : "Descending"
    }
}
