import SwiftUI
import Observation

/// Global search: one /Users/{id}/Items?searchTerm call, results grouped by
/// type (Fladder's quick-search screen), 400 ms debounce.
@MainActor
@Observable
final class SearchModel {
    var term = ""
    private(set) var groups: [(title: String, items: [BaseItem])] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func termChanged(client: JellyfinClient) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            groups = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.search(term: trimmed, client: client)
        }
    }

    private func search(term: String, client: JellyfinClient) async {
        errorMessage = nil
        do {
            var query = JellyfinClient.ItemsQuery()
            query.searchTerm = term
            query.recursive = true
            query.includeItemTypes = ["Movie", "Series", "Episode", "BoxSet", "Person", "TvChannel"]
            query.sortBy = "SortName"
            query.limit = 60
            let result = try await client.items(query)
            guard !Task.isCancelled else { return }
            let items = result.items ?? []
            let order: [(ItemType, String)] = [
                (.movie, "Movies"),
                (.series, "Series"),
                (.episode, "Episodes"),
                (.boxSet, "Collections"),
                (.person, "People"),
                (.tvChannel, "Channels"),
            ]
            groups = order.compactMap { type, title in
                let matches = items.filter { $0.type == type }
                return matches.isEmpty ? nil : (title, matches)
            }
            isSearching = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var model = SearchModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(model.groups, id: \.title) { group in
                    #if os(tvOS)
                    // tvOS's searchable keyboard owns the top of the screen;
                    // below it results wrap into a focus grid so the remote's
                    // swipes move across and down instead of along one long
                    // horizontal strip per group.
                    TVResultGrid(title: group.title, items: group.items, thumb: group.title == "Episodes")
                    #else
                    MediaRow(
                        title: group.title,
                        items: group.items,
                        style: group.title == "Episodes" ? .thumb : .poster)
                    #endif
                }
            }
            .padding(.vertical, 20)
        }
        .overlay {
            overlayContent
        }
        .navigationTitle("Search")
        .searchable(text: $model.term, prompt: "Movies, shows, people…")
        .onChange(of: model.term) {
            if let client = app.client {
                model.termChanged(client: client)
            }
        }
        #if DEBUG && os(tvOS)
        .onAppear {
            // -SearchQuery "the office": seed the field. `.searchable` on tvOS
            // is driven by the on-screen keyboard, which simctl cannot type
            // into, so this is the only way the harness can photograph results.
            if let seeded = UserDefaults.standard.string(forKey: "SearchQuery"),
               !seeded.isEmpty, model.term.isEmpty, let client = app.client {
                model.term = seeded
                model.termChanged(client: client)
            }
        }
        #endif
    }

    /// tvOS: keep results on screen while a refinement is in flight instead of
    /// covering them with a spinner on every debounce; the spinner only stands
    /// in when there is nothing to show yet.
    private var showsSearchingOverlay: Bool {
        #if os(tvOS)
        model.isSearching && model.groups.isEmpty
        #else
        model.isSearching
        #endif
    }

    @ViewBuilder
    private var overlayContent: some View {
        if showsSearchingOverlay {
            CenteredProgressView()
        } else if model.isSearching {
            EmptyView()
        } else if let error = model.errorMessage {
            ErrorRetryView(message: error) {
                if let client = app.client {
                    model.termChanged(client: client)
                }
            }
        } else if model.groups.isEmpty {
            if model.term.trimmingCharacters(in: .whitespaces).count >= 2 {
                ContentUnavailableView.search(text: model.term)
            } else {
                ContentUnavailableView(
                    "Search your server",
                    systemImage: "magnifyingglass",
                    description: Text("Find movies, shows, episodes, collections, and people."))
            }
        }
    }
}

#if os(tvOS)
/// One result group as a wrapping grid of `.card`-styled tiles at the Libraries
/// grid's poster size (250pt, six across) rather than round 1's 220pt seven.
/// Six, not five: the tvOS search keyboard owns the top 400pt, and six across
/// is the largest poster whose caption still lands above the fold, so the
/// first row reads whole without a scroll.
private struct TVResultGrid: View {
    let title: String
    let items: [BaseItem]
    let thumb: Bool

    /// `.searchable` on tvOS already insets its results by the 80pt safe
    /// margin; this is the extra our grid adds so it lines up with the keyboard.
    private static let inset: CGFloat = 40
    private var perRow: Int { thumb ? 3 : 6 }
    private var tileWidth: CGFloat {
        let safe: CGFloat = 1920 - (TVHome.margin + Self.inset) * 2
        return (safe - TVHome.cardSpacing * CGFloat(perRow - 1)) / CGFloat(perRow)
    }
    private var tileHeight: CGFloat { thumb ? tileWidth * 9 / 16 : tileWidth * 3 / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, Self.inset)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: TVHome.cardSpacing), count: perRow),
                alignment: .leading,
                spacing: TVHome.rowSpacing
            ) {
                ForEach(items) { item in
                    TVResultCard(item: item, thumb: thumb, width: tileWidth, height: tileHeight)
                }
            }
            .padding(.horizontal, Self.inset)
            // Room for the focused card's lift so the scroll view doesn't clip it.
            .padding(.vertical, 16)
        }
    }
}

/// Artwork *and* caption inside one `.card` link. Round 1 drew the caption
/// as an overlay outside the button, so under focus the tile scaled and
/// overran its own title; here the caption lifts with the tile because it is
/// part of what the focus engine is scaling.
private struct TVResultCard: View {
    let item: BaseItem
    let thumb: Bool
    let width: CGFloat
    let height: CGFloat

    @Environment(AppState.self) private var app

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(url: app.client?.imageURL(thumb ? item.thumbRef : item.posterRef, maxWidth: Int(width * 2)))
                    .frame(width: width, height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: TVHome.cardCornerRadius, style: .continuous))
                // 29pt is the ten-foot floor; `.caption` (20pt) was under it.
                // Two reserved lines: long titles wrap instead of truncating to
                // "The 40 Y…", and every card in a row stays the same height.
                Text(item.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .padding(.horizontal, 6)
                Text(item.posterSubtitle ?? " ")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.card)
    }
}
#endif
