import SwiftUI
import Observation

/// Paged, sortable item grid for a library view, folder, box set, or person —
/// Fladder's "library search" surface, reduced to the viewer essentials.
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
            errorMessage = error.localizedDescription
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

struct LibraryGridView: View {
    @Environment(AppState.self) private var app
    @State private var model: LibraryGridModel
    @State private var showFilters = false

    init(container: BaseItem) {
        _model = State(initialValue: LibraryGridModel(container: container))
    }

    private var columns: [GridItem] {
        let factor = app.settings.posterScale.factor
        return [GridItem(.adaptive(minimum: 130 * factor, maximum: 195 * factor), spacing: 14)]
    }

    var body: some View {
        Group {
            if let error = model.errorMessage, !model.hasLoaded {
                ErrorRetryView(message: error) {
                    Task { await reload() }
                }
            } else if !model.hasLoaded {
                CenteredProgressView()
            } else {
                grid
            }
        }
        .navigationTitle(model.container.displayTitle)
        .toolbar { toolbarContent }
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
        .sheet(isPresented: $showFilters, onDismiss: { Task { await reload() } }) {
            LibraryFilterSheet(model: model)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 520)
                #endif
        }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.reload(client: client)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.items) { item in
                    GridPosterCell(item: item)
                        .onAppear {
                            if let client = app.client {
                                model.loadMoreIfNeeded(current: item, client: client)
                            }
                        }
                }
            }
            .padding(16)

            if model.isLoading, model.hasLoaded {
                ProgressView()
                    .padding(.bottom, 24)
            }
        }
        .overlay {
            if model.hasLoaded, model.items.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("No items match the current filters."))
            }
        }
        // Pinch adjusts the global poster size (Fladder's pinch-to-zoom).
        .simultaneousGesture(
            MagnifyGesture()
                .onEnded { value in
                    if value.magnification > 1.15, let larger = app.settings.posterScale.larger {
                        withAnimation { app.settings.posterScale = larger }
                    } else if value.magnification < 0.87, let smaller = app.settings.posterScale.smaller {
                        withAnimation { app.settings.posterScale = smaller }
                    }
                })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(LibraryGridModel.Sort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    Picker("Order", selection: $model.ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                }

                Button {
                    showFilters = true
                } label: {
                    Label(
                        model.activeFilterCount > 0 ? "Filters (\(model.activeFilterCount))" : "Filters",
                        systemImage: model.activeFilterCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
            }
            .onChange(of: model.sort) { Task { await reload() } }
            .onChange(of: model.ascending) { Task { await reload() } }
        }
    }
}

/// Grid cell sized by the grid column rather than a fixed width.
struct GridPosterCell: View {
    let item: BaseItem
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: app.client?.imageURL(item.posterRef, maxWidth: 400))
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .overlay(alignment: .bottom) {
                        if let progress = item.progressFraction {
                            ProgressBar(fraction: progress)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let count = item.userData?.unplayedItemCount, count > 0 {
                            Text("\(count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.blue, in: Capsule())
                                .padding(6)
                        } else if item.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, .blue)
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(item.posterSubtitle ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
