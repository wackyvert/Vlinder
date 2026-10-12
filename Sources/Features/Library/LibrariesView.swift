import SwiftUI
import Observation

/// Grid of the user's library views; tapping one opens the paged item grid.
@MainActor
@Observable
final class LibrariesModel {
    private(set) var views: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    /// Real artwork for each library, keyed by view id; see `LibraryTile`.
    private(set) var previews: [String: LibraryTilePreview] = [:]

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Coalesced load — see the note on `HomeModel.load`: the fetch must outlive
    /// the view that started it, because SwiftUI discards its first copy of the
    /// split-view detail at launch.
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
            views = try await client.userViews()
            previews = previews.filter { id, _ in views.contains { $0.id == id } }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        if errorMessage == nil { await loadPreviews(client: client) }
    }

    /// One small page per library, all in parallel: the tiles draw from the
    /// library's own newest titles, so the screen never shows Jellyfin's
    /// stock cover art.
    private func loadPreviews(client: JellyfinClient) async {
        await withTaskGroup(of: (String, LibraryTilePreview)?.self) { group in
            for view in views {
                group.addTask {
                    guard let preview = await LibraryTilePreview.load(for: view, client: client) else { return nil }
                    return (view.id, preview)
                }
            }
            for await result in group {
                if let (id, preview) = result {
                    previews[id] = preview
                }
            }
        }
    }
}

/// The handful of items a library tile is composed from.
struct LibraryTilePreview {
    /// Wide art behind the tile: the newest title that has a backdrop.
    var backdrop: BaseItem?
    /// Up to three posters fanned over the backdrop's right half.
    var posters: [BaseItem]
    /// Channel logos for the Live TV library, which has no posters.
    var channels: [BaseItem]
    var total: Int?

    static func load(for view: BaseItem, client: JellyfinClient) async -> LibraryTilePreview? {
        if view.collectionType == "livetv" {
            guard let channels = try? await client.liveTvChannels() else { return nil }
            // Sister feeds of one network sit next to each other in channel
            // order and carry the same mark, so the first six logos would be
            // six copies of one. Sample evenly across the lineup instead, and
            // still skip a name already shown (minus its feed number).
            let withLogos = channels.filter { $0.imageTags?["Primary"] != nil }
            let wanted = 6
            var picks: [BaseItem] = []
            var seenNetworks: Set<String> = []
            if !withLogos.isEmpty {
                let stride = max(1, withLogos.count / wanted)
                for index in Swift.stride(from: 0, to: withLogos.count, by: stride) where picks.count < wanted {
                    let channel = withLogos[index]
                    let network = channel.displayTitle
                        .trimmingCharacters(in: .decimalDigits.union(.whitespaces)).lowercased()
                    if seenNetworks.insert(network).inserted { picks.append(channel) }
                }
            }
            return LibraryTilePreview(
                backdrop: nil, posters: [], channels: picks, total: channels.count)
        }
        var query = JellyfinClient.ItemsQuery()
        query.parentId = view.id
        query.recursive = true
        query.sortBy = "DateCreated,SortName"
        query.sortOrder = "Descending"
        query.limit = 12
        switch view.collectionType {
        case "movies": query.includeItemTypes = ["Movie"]
        case "tvshows": query.includeItemTypes = ["Series"]
        case "music": query.includeItemTypes = ["MusicAlbum"]
        case "boxsets": query.includeItemTypes = ["BoxSet"]
        default: query.recursive = false
        }
        guard let result = try? await client.items(query) else { return nil }
        let items = result.items ?? []
        let backdrop = items.first { !($0.backdropImageTags ?? []).isEmpty }
        let posters = items.filter { $0.posterRef != nil }.prefix(3)
        return LibraryTilePreview(
            backdrop: backdrop, posters: Array(posters), channels: [], total: result.totalRecordCount)
    }
}

struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var model = LibrariesModel()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if DEBUG
    @Environment(\.navigationRouter) private var router
    @State private var autoPushed = false
    #endif

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 40), count: 2)
        #elseif os(iOS)
        sizeClass == .compact
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 360), spacing: 24)]
        #else
        [GridItem(.adaptive(minimum: 360), spacing: 24)]
        #endif
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
                ScrollView {
                    VStack(alignment: .leading, spacing: TenFoot.isTV ? 38 : 28) {
                        galleryHeader
                        if let error = model.errorMessage {
                            HStack {
                                Text(error).font(.callout)
                                Spacer()
                                Button("Retry") { Task { await reload() } }
                            }
                            .foregroundStyle(.secondary)
                        }
                        if model.views.isEmpty {
                            ContentUnavailableView(
                                "No libraries yet", systemImage: "square.stack",
                                description: Text("Libraries added to your Jellyfin account will appear here."))
                                .frame(maxWidth: .infinity)
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading,
                                      spacing: TenFoot.isTV ? 40 : 24) {
                                ForEach(model.views) { view in
                                    libraryCard(view)
                                }
                            }
                        }
                    }
                    .padding(gridInsets)
                    .frame(maxWidth: TenFoot.isTV ? .infinity : 1440)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
            }
        }
        .background(LibraryGallery.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if os(tvOS) || os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Libraries")
        #endif
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
        #if DEBUG
        .onChange(of: model.views, initial: true) {
            guard !autoPushed, !model.views.isEmpty else { return }
            #if !os(tvOS)
            if let match = AtriumAutopilot.matchLibrary(in: model.views) {
                autoPushed = true
                router?.open(match)
                return
            }
            #endif
            if LibraryAutopilot.isActive {
                autoPushed = true
                Task { await LibraryAutopilot.run(views: model.views, client: app.client, router: router) }
            }
        }
        #endif
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.load(client: client)
    }

    private var galleryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                galleryTitle
                Spacer(minLength: 0)
                libraryCount
            }
            VStack(alignment: .leading, spacing: 8) {
                galleryTitle
                libraryCount
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var galleryTitle: some View {
        Text("Your collection")
            .font(.system(size: TenFoot.isTV ? 54 : 38, weight: .regular, design: .serif))
            .foregroundStyle(LibraryGallery.pearl)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var libraryCount: some View {
        Text("\(model.views.count.formatted()) \(model.views.count == 1 ? "library" : "libraries")")
            .font(TenFoot.isTV ? .body : .subheadline)
            .foregroundStyle(LibraryGallery.muted)
            .fixedSize()
    }

    private var gridInsets: EdgeInsets {
        #if os(tvOS)
        EdgeInsets(top: 32, leading: TVHome.margin, bottom: 64, trailing: TVHome.margin)
        #else
        EdgeInsets(top: 32, leading: 24, bottom: 40, trailing: 24)
        #endif
    }

    private func libraryCard(_ view: BaseItem) -> some View {
        NavigationLink(value: view) {
            LibraryTile(view: view, preview: model.previews[view.id])
        }
        .tileButtonStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([view.displayTitle, model.previews[view.id]?.countLabel(for: view)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens this library")
    }
}

private enum LibraryGallery {
    static let ink = Color(red: 0.035, green: 0.065, blue: 0.11)
    static let pearl = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let muted = Color(red: 0.60, green: 0.68, blue: 0.77)
    static let accent = Color(red: 0.56, green: 0.71, blue: 0.88)
}

extension LibraryTilePreview {
    func countLabel(for view: BaseItem) -> String? {
        guard let total else { return nil }
        let noun: String
        switch view.collectionType {
        case "movies": noun = total == 1 ? "film" : "films"
        case "tvshows": noun = "series"
        case "music": noun = total == 1 ? "album" : "albums"
        case "livetv": noun = total == 1 ? "channel" : "channels"
        case "boxsets": noun = total == 1 ? "collection" : "collections"
        default: noun = total == 1 ? "item" : "items"
        }
        return "\(total.formatted()) \(noun)"
    }
}

/// A cinematic window into a collection, made from its own artwork.
/// Geometry constrains every image before clipping, including narrow phones.
struct LibraryTile: View {
    let view: BaseItem
    let preview: LibraryTilePreview?

    @Environment(AppState.self) private var app
    @State private var hovered = false

    var body: some View {
        Color.clear
            .aspectRatio(TenFoot.isTV ? 2.05 : 1.72, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    composition(size: geometry.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(hovered ? LibraryGallery.accent.opacity(0.8) : .white.opacity(0.12),
                                  lineWidth: hovered ? 2 : 1)
            }
            #if !os(tvOS)
            .onHover { hovered = $0 }
            #endif
    }

    private func composition(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            background(size: size)
            LinearGradient(
                stops: [
                    .init(color: LibraryGallery.ink.opacity(0.12), location: 0),
                    .init(color: LibraryGallery.ink.opacity(0.45), location: 0.5),
                    .init(color: LibraryGallery.ink.opacity(0.98), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [LibraryGallery.ink.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
            artwork(size: size)
            label(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func background(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop = preview?.backdrop {
                RemoteImage(url: app.client?.imageURL(backdrop.backdropRef, maxWidth: 1400))
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size.height * 0.52, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(size.height * 0.1)
            }
        }
    }

    @ViewBuilder
    private func artwork(size: CGSize) -> some View {
        if let channels = preview?.channels, !channels.isEmpty {
            channelWall(channels, size: size)
        } else if let posters = preview?.posters, !posters.isEmpty {
            posterShelf(posters, size: size)
        }
    }

    private func posterShelf(_ posters: [BaseItem], size: CGSize) -> some View {
        let height = size.height * 0.43
        let width = view.collectionType == "music" ? height : height * 2 / 3
        return HStack(alignment: .top, spacing: size.width * 0.014) {
            ForEach(Array(posters.enumerated()), id: \.element.id) { index, item in
                RemoteImage(url: app.client?.imageURL(item.posterRef, maxWidth: 360))
                    .frame(width: width, height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
                    .padding(.top, CGFloat(index) * size.height * 0.035)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(size.height * 0.09)
    }

    private func channelWall(_ channels: [BaseItem], size: CGSize) -> some View {
        let width = size.width * 0.15
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 8), count: 3), spacing: 8) {
            ForEach(channels) { channel in
                RemoteImage(url: app.client?.imageURL(
                    itemId: channel.id, type: .primary,
                    tag: channel.imageTags?["Primary"], maxHeight: 180), contentMode: .fit)
                    .padding(10)
                    .frame(width: width, height: size.height * 0.19)
                    .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(size.height * 0.09)
    }

    private func label(size: CGSize) -> some View {
        let inset = size.height * 0.09
        return VStack(alignment: .leading, spacing: TenFoot.isTV ? 12 : 8) {
            Image(systemName: symbol)
                .font(TenFoot.isTV ? .title3 : .callout)
                .foregroundStyle(LibraryGallery.accent)
            Text(view.displayTitle)
                .font(.system(size: TenFoot.isTV ? 44 : 30, weight: .semibold))
                .foregroundStyle(LibraryGallery.pearl)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            HStack {
                Text(preview?.countLabel(for: view) ?? "Explore library")
                    .font(TenFoot.isTV ? .body : .subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(TenFoot.isTV ? .title3 : .body)
                    .foregroundStyle(hovered ? LibraryGallery.pearl : LibraryGallery.accent)
            }
        }
        .padding(inset)
    }

    private var symbol: String {
        switch view.collectionType {
        case "movies": "film"
        case "tvshows": "tv"
        case "music": "music.note"
        case "livetv": "antenna.radiowaves.left.and.right"
        case "boxsets": "square.stack"
        case "homevideos": "video"
        case "photos", "homevideos,photos": "photo"
        case "books": "book"
        default: "folder"
        }
    }

    private var tint: [Color] {
        switch view.collectionType {
        case "movies": [Color(red: 0.25, green: 0.22, blue: 0.38), LibraryGallery.ink]
        case "tvshows": [Color(red: 0.10, green: 0.29, blue: 0.36), LibraryGallery.ink]
        case "livetv": [Color(red: 0.13, green: 0.25, blue: 0.45), LibraryGallery.ink]
        case "music": [Color(red: 0.34, green: 0.23, blue: 0.20), LibraryGallery.ink]
        default: [Color(red: 0.22, green: 0.28, blue: 0.33), LibraryGallery.ink]
        }
    }
}

#if DEBUG
/// Screenshot-harness deep links, shared by every platform:
///   -OpenLibrary <name|*>   push the library whose title matches (`*` = movies, else first)
///   -OpenItem <id|title>    push an item by Jellyfin id, or the first search hit for a title
/// Both may be given; the library goes first so Back lands on its grid.
enum LibraryAutopilot {
    static var libraryName: String? { UserDefaults.standard.string(forKey: "OpenLibrary") }
    static var itemQuery: String? { UserDefaults.standard.string(forKey: "OpenItem") }
    static var isActive: Bool { libraryName != nil || itemQuery != nil }

    @MainActor
    static func run(views: [BaseItem], client: JellyfinClient?, router: NavigationRouter?) async {
        if let name = libraryName {
            let match: BaseItem?
            if name == "*" {
                match = views.first { $0.collectionType == "movies" } ?? views.first
            } else {
                match = views.first { $0.displayTitle.localizedCaseInsensitiveCompare(name) == .orderedSame }
                    ?? views.first { $0.displayTitle.localizedCaseInsensitiveContains(name) }
            }
            if let match { router?.open(match) }
        }
        guard let query = itemQuery, let client else { return }
        let looksLikeId = query.count == 32 && query.allSatisfy(\.isHexDigit)
        if looksLikeId, let item = try? await client.item(id: query) {
            router?.open(item)
            return
        }
        // Titles first, episodes only as a fallback: "Friends" should open the
        // series, not the first episode whose name contains the word.
        var q = JellyfinClient.ItemsQuery()
        q.searchTerm = query
        q.recursive = true
        q.includeItemTypes = ["Movie", "Series"]
        q.limit = 20
        let titles = (try? await client.items(q))?.items ?? []
        if let item = titles.first(where: { $0.displayTitle.localizedCaseInsensitiveCompare(query) == .orderedSame })
            ?? titles.first {
            router?.open(item)
            return
        }
        q.includeItemTypes = ["Episode"]
        q.limit = 1
        if let item = (try? await client.items(q))?.items?.first {
            router?.open(item)
        }
    }
}
#endif
