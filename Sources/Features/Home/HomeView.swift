import SwiftUI
import Observation

/// Fladder dashboard equivalent: Continue Watching, Next Up, On Now (live TV),
/// then a "Recently added in <library>" row per library view.
@MainActor
@Observable
final class HomeModel {
    struct LatestRow: Identifiable {
        var view: BaseItem
        var items: [BaseItem]
        var id: String { view.id }
    }

    private(set) var resume: [BaseItem] = []
    private(set) var resumeAudio: [BaseItem] = []
    private(set) var nextUp: [BaseItem] = []
    private(set) var channels: [BaseItem] = []
    private(set) var latestRows: [LatestRow] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Combined next-up + continue-watching for the hero carousel.
    var bannerItems: [BaseItem] {
        var seen = Set<String>()
        var combined: [BaseItem] = []
        for item in nextUp + resume where seen.insert(item.id).inserted {
            combined.append(item)
        }
        return Array(combined.prefix(8))
    }

    func load(client: JellyfinClient) async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let views = try await client.userViews()
            async let resumeItems = client.resumeItems(limit: 16)
            async let resumeAudioItems = client.resumeItems(limit: 16, mediaTypes: "Audio")
            async let nextUpItems = client.nextUp(limit: 16)

            let hasLiveTV = views.contains { $0.collectionType == "livetv" }
            async let channelItems: [BaseItem] = hasLiveTV ? client.liveTvChannels() : []

            // One "recently added" row per media library, mirroring Fladder.
            let rowViews = views.filter { view in
                switch view.collectionType {
                case "movies", "tvshows", "homevideos", "boxsets", "mixed", nil:
                    return true
                default:
                    return false
                }
            }
            var rows: [LatestRow] = []
            try await withThrowingTaskGroup(of: (Int, LatestRow).self) { group in
                for (index, view) in rowViews.enumerated() {
                    group.addTask {
                        let items = try await client.latest(parentId: view.id, limit: 16)
                        return (index, LatestRow(view: view, items: items))
                    }
                }
                var collected: [(Int, LatestRow)] = []
                for try await entry in group { collected.append(entry) }
                rows = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            self.resume = try await resumeItems
            self.resumeAudio = (try? await resumeAudioItems) ?? []
            self.nextUp = try await nextUpItems
            let liveChannels = (try? await channelItems) ?? []
            self.channels = Array(liveChannels.filter { $0.currentProgram != nil }.prefix(16))
            self.latestRows = rows.filter { !$0.items.isEmpty }
            self.hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var model = HomeModel()

    var body: some View {
        Group {
            if let error = model.errorMessage, !model.hasLoaded {
                ErrorRetryView(message: error) {
                    Task { await reload() }
                }
            } else if !model.hasLoaded {
                CenteredProgressView()
            } else {
                content
            }
        }
        .navigationTitle("Home")
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.load(client: client)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if app.settings.showHomeBanner {
                    HomeBanner(items: model.bannerItems)
                }
                MediaRow(title: "Continue Watching", items: model.resume, style: .thumb)
                MediaRow(title: "Next Up", items: model.nextUp, style: .thumb)
                if !model.channels.isEmpty {
                    onNowRow
                }
                MediaRow(title: "Continue Listening", items: model.resumeAudio, style: .square)
                ForEach(model.latestRows) { row in
                    MediaRow(title: "Recently added in \(row.view.displayTitle)", items: row.items)
                }
            }
            .padding(.vertical, 20)
        }
        #if os(macOS)
        .toolbar {
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        #endif
    }

    private var onNowRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On Now")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.channels) { channel in
                        ChannelCard(channel: channel)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
