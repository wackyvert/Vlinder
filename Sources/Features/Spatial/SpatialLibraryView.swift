import SwiftUI

/// SwiftUI composition of the Atrium: hosts the SceneKit view, mirrors the
/// shelf currently standing — the library, or a show's seasons or episodes
/// opened on top of it — into the scene, shows the native selection overlay,
/// and routes anything that leaves the room to the existing `ItemDetailView`.
struct SpatialLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.navigationRouter) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let model: LibraryGridModel

    @State private var controller = SpatialLibrarySceneController()
    @State private var browse = AtriumBrowseModel()
    @State private var selectedItem: BaseItem?
    @State private var syncedItemIds: [String] = []
    @State private var syncedShelfId: String?
    #if DEBUG
    @State private var autopilotRan = false
    #endif

    /// The shelf standing right now. The library is the floor of the stack and
    /// stays with the paged grid model; everything above it is a show's own.
    private var level: AtriumBrowseModel.Level? { browse.current }
    private var shelfItems: [BaseItem] { level?.items ?? model.items }
    private var shelfId: String { level?.id ?? "" }

    var body: some View {
        SpatialLibraryRepresentable(controller: controller)
            .accessibilityRepresentation { accessibleFallback }
            .overlay(alignment: .topLeading) {
                if !browse.isAtRoot {
                    AtriumBreadcrumb(
                        path: browse.breadcrumb(root: model.container.displayTitle),
                        onSelect: { depth in
                            browse.pop(toDepth: depth)
                            controller.focusSceneView()
                        })
                        .padding(.leading, 22)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: overlayAlignment) {
                if let item = selectedItem {
                    SpatialSelectionOverlay(
                        item: item,
                        browseLabel: item.atriumOpensAShelf ? browseLabel(for: item) : nil,
                        onBrowse: { descend(item) },
                        onOpen: { openDetails(item) },
                        onPlay: item.isPlayable ? { play(item) } : nil,
                        onClose: { controller.setSelection(nil) })
                    .padding(.trailing, isCompact ? 16 : 30)
                    .padding(.leading, isCompact ? 16 : 0)
                    .padding(.bottom, isCompact ? 16 : 0)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if isPagingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 14)
                }
            }
            .overlay { shelfStatus }
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: selectedItem?.id)
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.22), value: shelfId)
            .onChange(of: shelfItems, initial: true) {
                // wireController must run before the first sync mounts a case,
                // and SwiftUI fires initial onChange actions before onAppear.
                wireController()
                syncShelf()
            }
            .onChange(of: shelfId) { syncShelf() }
            .onChange(of: colorScheme) { controller.setAppearance(dark: colorScheme == .dark) }
            .onChange(of: reduceMotion) { controller.reduceMotion = reduceMotion }
    }

    // MARK: - Wiring

    private func wireController() {
        controller.reduceMotion = reduceMotion
        controller.setAppearance(dark: colorScheme == .dark)
        controller.setArtworkSource(.init(
            cover: { item, maxWidth in
                app.client?.imageURL(item.atriumArtRef, maxWidth: maxWidth)
            }))
        controller.onSelectionChange = { selectedItem = $0 }
        controller.onOpenItem = { activate($0) }
        controller.onPlayItem = { item in
            guard item.isPlayable else { return }
            play(item)
        }
        controller.onBack = { browse.pop() }
        controller.onNeedsNextPage = {
            // Only the library is paged; a show hands over all of itself at once.
            guard browse.isAtRoot, let client = app.client, let last = model.items.last
            else { return }
            model.loadMoreIfNeeded(current: last, client: client)
        }
    }

    /// Mirrors the standing shelf into the scene. A pure page-append extends the
    /// run in place; a new shelf — or anything else — is restood from scratch,
    /// and a shelf being returned to comes back at the case it was left on.
    private func syncShelf() {
        let ids = shelfItems.map(\.id)
        let sameShelf = shelfId == syncedShelfId
        guard !sameShelf || ids != syncedItemIds else { return }

        let isAppend = sameShelf
            && !syncedItemIds.isEmpty
            && ids.count >= syncedItemIds.count
            && Array(ids.prefix(syncedItemIds.count)) == syncedItemIds
        controller.update(
            items: shelfItems,
            totalCount: browse.isAtRoot ? model.total : shelfItems.count,
            reset: !isAppend)
        syncedItemIds = ids
        syncedShelfId = shelfId

        if let restored = browse.takePendingFocus(), !shelfItems.isEmpty {
            controller.sift(toIndex: restored, animated: false)
        }
        if let selected = selectedItem, !ids.contains(selected.id) {
            selectedItem = nil
        }
        #if DEBUG
        runAutopilotIfNeeded()
        #endif
    }

    /// The jacket comes out just left of centre, so its details sit to the right
    /// of it and the two read as one object. A phone has no right to spare, so
    /// there the details sit along the bottom instead.
    private var overlayAlignment: Alignment { isCompact ? .bottom : .trailing }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    // MARK: - Actions

    /// Return, or the overlay's leading button: a show opens onto its own shelf,
    /// anything else leaves the Atrium for its detail screen.
    private func activate(_ item: BaseItem) {
        if item.atriumOpensAShelf {
            descend(item)
        } else {
            openDetails(item)
        }
    }

    private func descend(_ item: BaseItem) {
        guard let client = app.client else { return }
        browse.descend(into: item, from: controller.focusedIndex, client: client)
        controller.focusSceneView()
    }

    private func openDetails(_ item: BaseItem) {
        router?.open(item)
    }

    /// Mirrors the detail screen's plain play path: resume position comes from
    /// the item's own user data; track selection stays with server defaults.
    /// Inside a season the shelf is the queue, so an episode rolls on into the
    /// next one exactly as it does from the episode list.
    private func play(_ item: BaseItem) {
        guard let client = app.client else { return }
        let queue = level?.kind == .episodes ? shelfItems : []
        player.play(item: item, queue: queue, client: client, settings: app.settings)
    }

    /// What the overlay's leading button promises. A show with a single season
    /// opens straight onto its episodes, and says so.
    private func browseLabel(for item: BaseItem) -> String {
        if item.type == .season { return "Browse Episodes" }
        return (item.childCount ?? 0) == 1 ? "Browse Episodes" : "Browse Seasons"
    }

    // MARK: - Shelf state

    private var isPagingMore: Bool {
        browse.isAtRoot ? (model.isLoading && model.hasLoaded) : false
    }

    @ViewBuilder
    private var shelfStatus: some View {
        if let level, level.items.isEmpty {
            if level.isLoading {
                ProgressView()
            } else if let error = level.errorMessage {
                ErrorRetryView(message: error) {
                    guard let client = app.client else { return }
                    browse.retry(client: client)
                }
            } else {
                ContentUnavailableView(
                    level.kind == .seasons ? "No seasons" : "No episodes",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("\(level.title) has nothing on the shelf."))
            }
        } else if browse.isAtRoot, model.hasLoaded, model.items.isEmpty {
            ContentUnavailableView(
                "Nothing on the shelf",
                systemImage: "books.vertical",
                description: Text("No items match the current filters."))
        }
    }

    // MARK: - Accessibility fallback

    /// VoiceOver browses the standing shelf as a flat, non-lazy list of buttons —
    /// a lazy container would only realize a subset of its rows when the
    /// accessibility tree is built. Each entry carries the same state the poster
    /// shows in 3D, and paging is an explicit action because a representation
    /// view is never scrolled and so never fires onAppear.
    private var accessibleFallback: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !browse.isAtRoot {
                let path = browse.breadcrumb(root: model.container.displayTitle)
                Button("Back to \(path[path.count - 2])") { browse.pop() }
            }

            ForEach(shelfItems) { item in
                Button {
                    activate(item)
                } label: {
                    Text(accessibilityLabel(for: item))
                }
                .accessibilityHint(Text(item.atriumOpensAShelf
                    ? browseLabel(for: item)
                    : "Opens details"))
                .modifier(PlayAccessibilityAction(
                    play: item.isPlayable ? { play(item) } : nil))
            }

            if browse.isAtRoot, let total = model.total, model.items.count < total {
                Button("Load more items") {
                    guard let client = app.client, let last = model.items.last else { return }
                    model.loadMoreIfNeeded(current: last, client: client)
                }
                .accessibilityHint(Text("\(model.items.count) of \(total) loaded"))
            }
        }
        .accessibilityLabel(Text(
            "\(browse.breadcrumb(root: model.container.displayTitle).joined(separator: ", ")) gallery"))
    }

    /// Everything a case encodes visually, spoken in one phrase.
    private func accessibilityLabel(for item: BaseItem) -> String {
        var parts = [item.displayTitle]
        if let subtitle = item.posterSubtitle { parts.append(subtitle) }
        if let runtime = item.runtimeLabel { parts.append(runtime) }
        if let fraction = item.progressFraction {
            parts.append("\(Int((fraction * 100).rounded()))% watched")
        } else if let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            parts.append("\(unplayed) unwatched")
        } else if item.userData?.played == true {
            parts.append("Watched")
        }
        return parts.joined(separator: ", ")
    }

    #if DEBUG
    private func runAutopilotIfNeeded() {
        guard !autopilotRan, !shelfItems.isEmpty else { return }
        let sift = AtriumAutopilot.scrollBay
        let select = AtriumAutopilot.selectIndex
        let steps = AtriumAutopilot.descendSteps ?? 0
        guard sift != nil || select != nil || steps > 0 else { return }
        autopilotRan = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if let sift {
                controller.sift(toIndex: sift, animated: false)
            }
            if let select {
                controller.setSelection(select)
            }
            // Walk down into the show, waiting for each shelf to arrive.
            for _ in 0..<steps {
                guard let item = controller.selectedItem, item.atriumOpensAShelf else { break }
                descend(item)
                for _ in 0..<40 where browse.current?.isLoading != false {
                    try? await Task.sleep(for: .seconds(0.25))
                }
                try? await Task.sleep(for: .seconds(0.7))
                controller.setSelection(0)
            }
        }
    }
    #endif
}

/// Adds a Play action only for items that can actually be played, so VoiceOver
/// never announces an action that does nothing.
private struct PlayAccessibilityAction: ViewModifier {
    let play: (() -> Void)?

    func body(content: Content) -> some View {
        if let play {
            content.accessibilityAction(named: Text("Play"), play)
        } else {
            content
        }
    }
}

/// Where in the shelves the viewer currently is, and the way back out. Each
/// crumb but the last returns to that shelf, at the case it was left on.
private struct AtriumBreadcrumb: View {
    let path: [String]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button {
                onSelect(max(0, path.count - 2))
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Back to \(path.count >= 2 ? path[path.count - 2] : "the shelf") (Esc)")
            .accessibilityLabel(Text("Back"))

            ForEach(Array(path.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                if index == path.count - 1 {
                    Text(crumb)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    Button(crumb) { onSelect(index) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Native metadata panel for the selected case — flat, disciplined, readable
/// with VoiceOver and large type. All actions reuse existing paths.
struct SpatialSelectionOverlay: View {
    let item: BaseItem
    /// Set when the case opens onto a shelf of its own rather than a screen.
    var browseLabel: String?
    var onBrowse: () -> Void = {}
    let onOpen: () -> Void
    let onPlay: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.displayTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Clear selection"))
            }

            if let context = contextLine {
                Text(context)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let state = stateLine {
                Text(state)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let overview = trimmedOverview {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                // Whatever keeps the viewer in the room leads: opening a show
                // onto its own shelf, or playing what is in their hand.
                if let browseLabel {
                    Button {
                        onBrowse()
                    } label: {
                        Label(browseLabel, systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent)
                } else if let onPlay {
                    Button {
                        onPlay()
                    } label: {
                        Label(playLabel, systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Details leads only when nothing better can be done here.
                if browseLabel == nil, onPlay == nil {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 3)
        }
        .padding(17)
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.separator.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Three lines of overview, cut on a word boundary rather than mid-word.
    private var trimmedOverview: String? {
        guard let overview = item.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty
        else { return nil }
        let limit = 190
        guard overview.count > limit else { return overview }
        let head = overview.prefix(limit)
        guard let lastSpace = head.lastIndex(of: " ") else { return String(head) + "…" }
        let clipped = head[head.startIndex..<lastSpace]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-"))
        return clipped + "…"
    }

    /// Where this case sits in its show — the one thing a jacket alone cannot
    /// say once you are several shelves deep.
    private var contextLine: String? {
        switch item.type {
        case .episode:
            return [item.episodeLabel, item.seasonName ?? item.seriesName]
                .compactMap(\.self).joined(separator: "  ·  ")
        case .season:
            return item.seriesName
        default:
            return nil
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if item.type != .episode, let year = item.yearLabel {
            parts.append(year)
        }
        if let runtime = item.runtimeLabel {
            parts.append(runtime)
        }
        if item.type == .season || item.type == .series, let count = item.childCount, count > 0 {
            parts.append(item.type == .season
                ? "\(count) episode\(count == 1 ? "" : "s")"
                : "\(count) season\(count == 1 ? "" : "s")")
        }
        if let rating = item.communityRating {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var stateLine: String? {
        if let fraction = item.progressFraction {
            let percent = Int((fraction * 100).rounded())
            return "In progress · \(percent)% watched"
        }
        if let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            return "\(unplayed) unwatched"
        }
        if item.userData?.played == true {
            return "Watched"
        }
        return nil
    }

    private var playLabel: String {
        if let ticks = item.resumeTicks {
            let remaining = (item.runTime ?? 0) - TimeInterval(ticks) / 10_000_000
            if remaining > 60 {
                return "Resume · \(Int(remaining / 60)) min left"
            }
            return "Resume"
        }
        return "Play"
    }
}
