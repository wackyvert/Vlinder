import SwiftUI
import Observation

/// Series (and season) detail: hero header, next-up-aware play button,
/// season picker, episode list, cast, similar.
@MainActor
@Observable
final class SeriesDetailModel {
    let seriesId: String
    var series: BaseItem
    private(set) var seasons: [BaseItem] = []
    private(set) var episodes: [BaseItem] = []
    private(set) var nextEpisode: BaseItem?
    private(set) var similar: [BaseItem] = []
    var selectedSeasonId: String?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    init(seriesId: String, seed: BaseItem, focusSeasonId: String?) {
        self.seriesId = seriesId
        self.series = seed
        self.selectedSeasonId = focusSeasonId
    }

    func load(client: JellyfinClient) async {
        errorMessage = nil
        do {
            async let fullSeries = client.item(id: seriesId)
            async let seasonList = client.seasons(seriesId: seriesId)
            async let nextUpList = client.nextUp(limit: 1, seriesId: seriesId)
            async let similarList = client.similar(itemId: seriesId)

            series = try await fullSeries
            seasons = try await seasonList
            nextEpisode = (try? await nextUpList)?.first
            similar = (try? await similarList) ?? []

            if selectedSeasonId == nil {
                // Open on the next-up episode's season when there is one.
                selectedSeasonId = nextEpisode?.seasonId ?? seasons.first?.id
            }
            await loadEpisodes(client: client)
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadEpisodes(client: JellyfinClient) async {
        episodes = (try? await client.episodes(seriesId: seriesId, seasonId: selectedSeasonId)) ?? []
    }

    var selectedSeason: BaseItem? {
        seasons.first { $0.id == selectedSeasonId }
    }

    /// The play button's target: explicit next-up, else first not-fully-watched
    /// episode of the selected season, else the first episode.
    var playTarget: BaseItem? {
        if let nextEpisode { return nextEpisode }
        if let inProgress = episodes.first(where: { $0.resumeTicks != nil }) { return inProgress }
        if let unwatched = episodes.first(where: { $0.userData?.played != true }) { return unwatched }
        return episodes.first
    }
}

struct SeriesDetailView: View {
    @Environment(AppState.self) private var app
    @State private var model: SeriesDetailModel

    init(seriesId: String, seed: BaseItem, focusSeasonId: String? = nil) {
        _model = State(initialValue: SeriesDetailModel(
            seriesId: seriesId, seed: seed, focusSeasonId: focusSeasonId))
    }

    var body: some View {
        Group {
            if let error = model.errorMessage, !model.hasLoaded {
                ErrorRetryView(message: error) {
                    Task {
                        if let client = app.client { await model.load(client: client) }
                    }
                }
            } else {
                content
            }
        }
        .navigationTitle(model.series.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task {
            guard let client = app.client, !model.hasLoaded else { return }
            await model.load(client: client)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(item: model.series)

                VStack(alignment: .leading, spacing: 16) {
                    PlayControls(
                        item: model.series,
                        playTarget: model.playTarget,
                        queue: model.episodes,
                        onUserDataChanged: {
                            Task {
                                if let client = app.client { await model.load(client: client) }
                            }
                        })
                    OverviewText(item: model.series)
                }
                .padding(.horizontal, 20)

                episodesSection

                PeopleRow(people: model.series.people ?? [])

                if !model.similar.isEmpty {
                    MediaRow(title: "More Like This", items: model.similar)
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !model.seasons.isEmpty {
                    Picker("Season", selection: seasonSelection) {
                        ForEach(model.seasons) { season in
                            Text(season.displayTitle).tag(season.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(.horizontal, 20)

            if model.episodes.isEmpty, model.hasLoaded {
                Text("No episodes in this season.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(model.episodes) { episode in
                        EpisodeRow(episode: episode, queue: model.episodes)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var seasonSelection: Binding<String?> {
        Binding(
            get: { model.selectedSeasonId },
            set: { newValue in
                model.selectedSeasonId = newValue
                Task {
                    if let client = app.client {
                        await model.loadEpisodes(client: client)
                    }
                }
            })
    }
}

/// One episode in the season list: still, texts, quick-play button.
struct EpisodeRow: View {
    let episode: BaseItem
    var queue: [BaseItem] = []

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        NavigationLink(value: episode) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: app.client?.imageURL(episode.thumbRef, maxWidth: 480))
                    .frame(width: 164, height: 92)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if let progress = episode.progressFraction {
                            ProgressBar(fraction: progress)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .center) {
                        Button {
                            play()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.92), .black.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let index = episode.indexNumber {
                            Text("\(index).")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(episode.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if episode.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    if let runtime = episode.runtimeLabel {
                        Text(runtime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func play() {
        guard let client = app.client else { return }
        player.play(
            item: episode,
            queue: queue,
            client: client,
            settings: app.settings)
    }
}
