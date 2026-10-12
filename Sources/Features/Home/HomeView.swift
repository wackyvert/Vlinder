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

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Coalesced load. The fetch runs in an unstructured task so it survives the
    /// view being torn down mid-flight — SwiftUI builds the split-view detail
    /// twice at launch, and a structured `.task` fetch would be cancelled with
    /// the discarded copy while the replacement no-ops on an `isLoading` guard,
    /// stranding an error on screen. A second caller awaits the same work.
    func load(client: JellyfinClient) async {
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            await self?.performLoad(client: client)
            self?.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    private func performLoad(client: JellyfinClient) async {
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
        #if !os(tvOS)
        // The TV's tab bar already names the section; a stack title there is
        // drawn straight over the hero banner.
        .navigationTitle("Home")
        #endif
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
            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                if app.settings.showHomeBanner {
                    HomeBanner(items: model.bannerItems)
                }
                row("Continue Watching", model.resume, style: .thumb)
                #if os(tvOS)
                // Live TV second, so it sits at the fold of the first screen: a
                // ten-foot viewer expects "what's on" without scrolling for it.
                if !model.channels.isEmpty {
                    onNowRow
                }
                row("Next Up", model.nextUp, style: .thumb)
                #else
                row("Next Up", model.nextUp, style: .thumb)
                if !model.channels.isEmpty {
                    onNowRow
                }
                #endif
                row("Continue Listening", model.resumeAudio, style: .square)
                ForEach(model.latestRows) { latest in
                    row("Recently added in \(latest.view.displayTitle)", latest.items, style: .poster)
                }
            }
            #if os(tvOS)
            .padding(.bottom, TVHome.rowSpacing)
            #else
            .padding(.vertical, 20)
            #endif
        }
        #if os(tvOS)
        // tvOS insets scroll content by its 80×60 safe area on top of our own
        // TVHome.margin, which is what doubled the hero's inset to 160 and
        // pushed every shelf caption below the frame. Take the full frame and
        // apply the single 80pt margin ourselves; the hero runs edge to edge
        // and up behind the floating tab bar, as the Apple TV app's does.
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        #endif
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

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        TVHome.rowSpacing
        #else
        28
        #endif
    }

    /// The shared `MediaRow` is sized for a desk; the TV gets its own shelf.
    @ViewBuilder
    private func row(_ title: String, _ items: [BaseItem], style: MediaCard.Style) -> some View {
        #if os(tvOS)
        TVHomeRow(title: title, items: items, style: style)
        #else
        MediaRow(title: title, items: items, style: style)
        #endif
    }

    private var onNowRow: some View {
        #if os(tvOS)
        TVHomeShelf(title: "On Now") {
            ForEach(model.channels) { channel in
                TVChannelCard(channel: channel)
            }
        }
        #else
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
        #endif
    }
}

#if os(tvOS)
/// Couch metrics for the TV home: the safe-area margin Apple's own TV app
/// keeps, and shelf spacing that leaves room for the focus lift.
enum TVHome {
    static let margin: CGFloat = 80
    /// Full-bleed hero from y0 (the tab bar floats over its top). 40% of a
    /// 1080 frame: with the shelf pitch below (~330pt) the first shelf sits
    /// complete under it and the second shelf's title and the top of its
    /// cards show at the frame edge — the Apple TV app cuts the next row
    /// there on purpose so a down-press has a visible target. 520 left only
    /// 1.18 shelves in frame and sliced the second title at y1064.
    static let bannerHeight: CGFloat = 430
    static let rowSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 36
    static let cardCornerRadius: CGFloat = 16
    /// Room above a shelf's cards for the `.card` focus lift; below, for its
    /// shadow. Asymmetric because every point above the cards is a point the
    /// first shelf's captions lose at the bottom of the frame.
    static let shelfLiftRoom: CGFloat = 10
    static let shelfShadowRoom: CGFloat = 8
    /// Gap between a card and its caption, and the caption block's type.
    /// Together with the card these set the shelf pitch; the Apple TV app's
    /// Up Next cards are ~380 wide with a ~48pt caption, and matching that is
    /// what buys the second shelf.
    static let captionSpacing: CGFloat = 8
    static let captionTitleFont: Font = .subheadline.weight(.medium)
    static let captionSubtitleFont: Font = .caption2
    static let shelfTitleFont: Font = .title3.weight(.bold)
    /// Width of the fade over the shelf's trailing edge. Cards are laid out
    /// from the 80pt margin at a fixed pitch, so whichever card straddles
    /// x=1920 is cut mid-image and its caption breaks mid-word ("The Mommy
    /// Obs"); fading that strip keeps the peek — "there is more to the
    /// right" — without a broken label. A focused card is scrolled fully into
    /// view by the focus engine, so the fade never sits on the focused one.
    static let trailingFade: CGFloat = 200
}

/// Titled horizontal shelf. The vertical padding and `scrollClipDisabled` keep
/// the focused card's lift and shadow from being cut by the scroll view.
struct TVHomeShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TVHome.shelfTitleFont)
                .padding(.horizontal, TVHome.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVHome.cardSpacing) {
                    content()
                }
                .padding(.horizontal, TVHome.margin)
                .padding(.top, TVHome.shelfLiftRoom)
                .padding(.bottom, TVHome.shelfShadowRoom)
            }
            .scrollClipDisabled()
            // Fade the partial card at the right edge (see trailingFade). The
            // mask is padded out past the shelf's bounds so it does not undo
            // scrollClipDisabled by clipping a lifted card's scale or shadow.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    // Reaches clear well before x=1920 so the peeking card's
                    // caption is gone, not merely dimmed and still legible.
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.6)],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: TVHome.trailingFade)
                }
                .padding(.vertical, -60)
                .padding(.leading, -60)
            }
        }
    }
}

/// tvOS twin of `MediaRow`: the same data and poster-scale setting, drawn at
/// a size that reads from ten feet.
struct TVHomeRow: View {
    let title: String
    let items: [BaseItem]
    var style: MediaCard.Style = .poster

    @Environment(AppState.self) private var app

    /// Fixed, not scaled by `posterScale`. That setting exists for a desk
    /// window whose width varies; the TV is always a 1920×1080 canvas whose
    /// vertical budget is the constraint. At "large" (×1.25) a 380 thumb
    /// became 475×267 and the second shelf fell out of the frame again. 380
    /// for 16:9 is the Apple TV app's Up Next card: four full cards plus a
    /// peek across the 1760pt content width.
    private var cardWidth: CGFloat {
        switch style {
        case .poster: 200
        case .thumb: 380
        case .square: 200
        }
    }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            TVHomeShelf(title: title) {
                ForEach(items) { item in
                    TVMediaCard(item: item, style: style, width: cardWidth)
                }
            }
        }
    }
}

/// Artwork inside a `.card` button so the focus engine lifts and scales it;
/// the caption stays put underneath, as in the system TV app.
struct TVMediaCard: View {
    let item: BaseItem
    var style: MediaCard.Style
    var width: CGFloat

    @Environment(AppState.self) private var app

    private var height: CGFloat { width / style.aspectRatio }

    private var imageRef: ImageRef? {
        switch style {
        case .poster, .square: item.posterRef
        case .thumb: item.thumbRef
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVHome.captionSpacing) {
            NavigationLink(value: item) {
                RemoteImage(url: app.client?.imageURL(imageRef, maxWidth: Int(width * 2)))
                    .frame(width: width, height: height)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if let progress = item.progressFraction {
                            ProgressBar(fraction: progress)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        statusBadge
                    }
                    .clipShape(RoundedRectangle(cornerRadius: TVHome.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(TVHome.captionTitleFont)
                    .lineLimit(1)
                Text(item.posterSubtitle ?? " ")
                    .font(TVHome.captionSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let count = item.userData?.unplayedItemCount, count > 0 {
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.blue, in: Capsule())
                .padding(10)
        } else if item.userData?.played == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, .blue)
                .padding(10)
        }
    }
}

/// Live channel tile for the "On Now" shelf; selecting it tunes straight in.
struct TVChannelCard: View {
    let channel: BaseItem
    /// Same width as the thumb cards above so the two shelves share a pitch.
    var width: CGFloat = 380

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: TVHome.captionSpacing) {
            Button {
                guard let client = app.client else { return }
                player.playChannel(channel, client: client, settings: app.settings)
            } label: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    RemoteImage(
                        url: app.client?.imageURL(
                            itemId: channel.id, type: .primary,
                            tag: channel.imageTags?["Primary"], maxHeight: 300),
                        contentMode: .fit)
                    .padding(24)
                }
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress = channel.currentProgramProgress {
                        ProgressBar(fraction: progress)
                            .frame(height: 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TVHome.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayTitle)
                    .font(TVHome.captionTitleFont)
                    .lineLimit(1)
                Text(channel.currentProgram?.value.name ?? " ")
                    .font(TVHome.captionSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: width)
    }
}
#endif
