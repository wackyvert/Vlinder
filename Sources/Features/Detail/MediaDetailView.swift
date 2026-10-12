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
    private(set) var specialFeatures: [BaseItem] = []
    private(set) var isLoading = false

    // Pre-play selections (TrackSelectionRow).
    var selectedSourceId: String?
    var audioIndex: Int?
    var subtitleIndex: Int?

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
        if item.type == .movie || item.type == .episode {
            specialFeatures = (try? await client.specialFeatures(itemId: item.id)) ?? []
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
                        mediaSourceId: model.selectedSourceId,
                        audioStreamIndex: model.audioIndex,
                        subtitleStreamIndex: model.subtitleIndex,
                        onUserDataChanged: {
                            Task {
                                if let client = app.client {
                                    await model.refreshUserData(client: client)
                                }
                            }
                        })
                    TrackSelectionRow(
                        item: model.item,
                        selectedSourceId: Binding(
                            get: { model.selectedSourceId },
                            set: { model.selectedSourceId = $0 }),
                        audioIndex: Binding(
                            get: { model.audioIndex },
                            set: { model.audioIndex = $0 }),
                        subtitleIndex: Binding(
                            get: { model.subtitleIndex },
                            set: { model.subtitleIndex = $0 }))
                    MediaInfoLine(item: model.item)
                    OverviewText(item: model.item)
                    ExternalLinksRow(item: model.item)
                }
                .padding(.horizontal, DetailMetrics.edge)

                ChapterRow(
                    item: model.item,
                    queue: model.item.type == .episode ? model.siblings : [])

                PeopleRow(people: model.item.people ?? [])

                if model.item.type == .episode, !model.siblings.isEmpty {
                    row(model.item.seasonName ?? "Episodes", model.siblings, style: .thumb)
                }

                if !model.specialFeatures.isEmpty {
                    row("Special Features", model.specialFeatures, style: .thumb)
                }

                if !model.similar.isEmpty {
                    row("More Like This", model.similar, style: .poster)
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        #if os(tvOS)
        // The hero already carries the title (or logo); the stack's grey copy
        // would float over the backdrop.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(model.item.displayTitle)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task(id: model.item.id) {
            guard let client = app.client else { return }
            await model.load(client: client)
        }
    }

    /// The shared `MediaRow` is sized for a desk; the TV uses the home shelf.
    @ViewBuilder
    private func row(_ title: String, _ items: [BaseItem], style: MediaCard.Style) -> some View {
        #if os(tvOS)
        TVHomeRow(title: title, items: items, style: style)
        #else
        MediaRow(title: title, items: items, style: style)
        #endif
    }
}
