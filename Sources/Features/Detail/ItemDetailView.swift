import SwiftUI

/// Routes a tapped item to the right detail experience by type
/// (Fladder's details route dispatch).
struct ItemDetailView: View {
    let item: BaseItem

    var body: some View {
        switch item.type {
        case .userView, .collectionFolder, .folder, .boxSet, .playlist, .photoAlbum, .genre:
            LibraryGridView(container: item)
        case .series:
            SeriesDetailView(seriesId: item.id, seed: item)
        case .season:
            SeriesDetailView(seriesId: item.seriesId ?? item.id, seed: item, focusSeasonId: item.id)
        case .person:
            PersonItemsView(person: item)
        case .tvChannel, .liveTvChannel:
            ChannelDetailView(channel: item)
        default:
            MediaDetailView(item: item)
        }
    }
}

/// Minimal channel screen for channels reached via search/navigation.
struct ChannelDetailView: View {
    let channel: BaseItem
    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 20) {
            RemoteImage(
                url: app.client?.imageURL(
                    itemId: channel.id, type: .primary,
                    tag: channel.imageTags?["Primary"], maxHeight: 300),
                contentMode: .fit)
                .frame(maxWidth: 280, maxHeight: 160)
            Text(channel.displayTitle)
                .font(.title.weight(.bold))
            if let program = channel.currentProgram?.value {
                Text(program.name ?? "")
                    .foregroundStyle(.secondary)
            }
            Button {
                guard let client = app.client else { return }
                player.playChannel(channel, client: client, settings: app.settings)
            } label: {
                Label("Watch", systemImage: "play.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(channel.displayTitle)
    }
}

/// Grid of everything a person appears in.
struct PersonItemsView: View {
    let person: BaseItem
    @Environment(AppState.self) private var app
    @State private var items: [BaseItem] = []
    @State private var loaded = false

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: TVHome.cardSpacing)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 14)]
    #endif

    var body: some View {
        ScrollView {
            #if os(tvOS)
            Text(person.displayTitle)
                .font(.title.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TVHome.margin)
                .padding(.top, 24)
            LazyVGrid(columns: columns, alignment: .leading, spacing: TVHome.rowSpacing) {
                ForEach(items) { item in
                    GridPosterCell(item: item)
                }
            }
            .padding(EdgeInsets(top: 28, leading: TVHome.margin, bottom: 40, trailing: TVHome.margin))
            #else
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    GridPosterCell(item: item)
                }
            }
            .padding(16)
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(person.displayTitle)
        #endif
        .overlay {
            if !loaded { CenteredProgressView() }
        }
        .task {
            guard let client = app.client, !loaded else { return }
            var query = JellyfinClient.ItemsQuery()
            query.personIds = [person.id]
            query.recursive = true
            query.includeItemTypes = ["Movie", "Series"]
            query.sortBy = "PremiereDate,SortName"
            query.sortOrder = "Descending"
            items = (try? await client.items(query))?.items ?? []
            loaded = true
        }
    }
}
