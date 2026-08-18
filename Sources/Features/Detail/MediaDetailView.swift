import SwiftUI
import Observation

/// Movie / episode / video detail: hero, play controls, overview, cast,
/// sibling episodes (for episodes), similar titles.
@MainActor
@Observable
final class MediaDetailModel {
    var item: BaseItem
    private(set) var siblings: [BaseItem] = []
    private(set) var similar: [BaseItem] = []
    private(set) var isLoading = false

    init(item: BaseItem) {
        self.item = item
    }

    func load(client: JellyfinClient) async {
        isLoading = true
        defer { isLoading = false }
        // Re-fetch the full item: list payloads lack people/mediaSources/chapters.
        if let full = try? await client.item(id: item.id) {
            item = full
        }
        if item.type == .episode, let seriesId = item.seriesId {
            siblings = (try? await client.episodes(seriesId: seriesId, seasonId: item.seasonId)) ?? []
        }
        if item.type == .movie || item.type == .series {
            similar = (try? await client.similar(itemId: item.id)) ?? []
        }
    }

    func refreshUserData(client: JellyfinClient) async {
        if let full = try? await client.item(id: item.id) {
            item = full
        }
    }
}

struct MediaDetailView: View {
    @Environment(AppState.self) private var app
    @State private var model: MediaDetailModel

    init(item: BaseItem) {
        _model = State(initialValue: MediaDetailModel(item: item))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(item: model.item)

                VStack(alignment: .leading, spacing: 16) {
                    PlayControls(
                        item: model.item,
                        queue: model.item.type == .episode ? model.siblings : [],
                        onUserDataChanged: {
                            Task {
                                if let client = app.client {
                                    await model.refreshUserData(client: client)
                                }
                            }
                        })
                    MediaInfoLine(item: model.item)
                    OverviewText(item: model.item)
                }
                .padding(.horizontal, 20)

                PeopleRow(people: model.item.people ?? [])

                if model.item.type == .episode, !model.siblings.isEmpty {
                    MediaRow(
                        title: model.item.seasonName ?? "Episodes",
                        items: model.siblings,
                        style: .thumb)
                }

                if !model.similar.isEmpty {
                    MediaRow(title: "More Like This", items: model.similar)
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.item.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task(id: model.item.id) {
            guard let client = app.client else { return }
            await model.load(client: client)
        }
    }
}
