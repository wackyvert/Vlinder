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
                    MediaRow(
                        title: group.title,
                        items: group.items,
                        style: group.title == "Episodes" ? .thumb : .poster)
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
    }

    @ViewBuilder
    private var overlayContent: some View {
        if model.isSearching {
            CenteredProgressView()
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
