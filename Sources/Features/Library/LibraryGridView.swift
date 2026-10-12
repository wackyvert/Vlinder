import SwiftUI

/// Paged, sortable item browser for a library view, folder, box set, or person —
/// Fladder's "library search" surface, reduced to the viewer essentials.
/// Hosts two presentations of the same `LibraryGridModel`: the poster grid and
/// the Atrium spatial gallery. Switching modes never refetches.
struct LibraryGridView: View {
    @Environment(AppState.self) private var app
    @State private var model: LibraryGridModel
    @State private var showFilters = false

    init(container: BaseItem) {
        _model = State(initialValue: LibraryGridModel(container: container))
    }

    private var columns: [GridItem] {
        let factor = app.settings.posterScale.factor
        #if os(tvOS)
        return [GridItem(.adaptive(minimum: 200 * factor, maximum: 260 * factor), spacing: TVHome.cardSpacing)]
        #else
        return [GridItem(.adaptive(minimum: 130 * factor, maximum: 195 * factor), spacing: 14)]
        #endif
    }

    private var viewMode: LibraryViewMode {
        #if DEBUG
        #if os(tvOS)
        return .grid
        #else
        if let forced = AtriumAutopilot.forceViewMode { return forced }
        #endif
        #endif
        return app.settings.libraryViewMode
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
                if viewMode == .atrium {
                    #if os(tvOS)
                    EmptyView()
                    #else
                    SpatialLibraryView(model: model)
                    #endif
                } else {
                    grid
                }
            }
        }
        #if os(tvOS)
        // No toolbar on the TV: the title and the sort/filter control live in
        // the grid's own header, where the remote can reach them.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(model.container.displayTitle)
        .toolbar { toolbarContent }
        #endif
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
        .sheet(isPresented: $showFilters, onDismiss: { Task { await reload() } }) {
            LibraryFilterSheet(model: model)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 520)
                #endif
        }
    }

    #if os(tvOS)
    /// Title, item count, and the one control the remote needs.
    private var tvHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(model.container.displayTitle)
                .font(.title.weight(.bold))
            if let total = model.total {
                Text("\(total)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showFilters = true
            } label: {
                Label(
                    model.activeFilterCount > 0 ? "Sort & Filter (\(model.activeFilterCount))" : "Sort & Filter",
                    systemImage: model.activeFilterCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
        }
        .padding(.horizontal, TVHome.margin)
        .padding(.top, 24)
    }
    #endif

    private func reload() async {
        guard let client = app.client else { return }
        await model.reload(client: client)
    }

    private var grid: some View {
        ScrollView {
            #if os(tvOS)
            tvHeader
            #endif
            LazyVGrid(columns: columns, alignment: .leading, spacing: gridRowSpacing) {
                ForEach(model.items) { item in
                    GridPosterCell(item: item)
                        .onAppear {
                            if let client = app.client {
                                model.loadMoreIfNeeded(current: item, client: client)
                            }
                        }
                }
            }
            .padding(gridInsets)

            if model.isLoading, model.hasLoaded {
                ProgressView()
                    .padding(.bottom, 24)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .overlay {
            if model.hasLoaded, model.items.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("No items match the current filters."))
            }
        }
        // Pinch adjusts the global poster size (Fladder's pinch-to-zoom).
        #if !os(tvOS)
        .simultaneousGesture(
            MagnifyGesture()
                .onEnded { value in
                    if value.magnification > 1.15, let larger = app.settings.posterScale.larger {
                        withAnimation { app.settings.posterScale = larger }
                    } else if value.magnification < 0.87, let smaller = app.settings.posterScale.smaller {
                        withAnimation { app.settings.posterScale = smaller }
                    }
                })
        #endif
    }

    private var gridRowSpacing: CGFloat {
        #if os(tvOS)
        TVHome.rowSpacing
        #else
        18
        #endif
    }

    private var gridInsets: EdgeInsets {
        #if os(tvOS)
        EdgeInsets(top: 28, leading: TVHome.margin, bottom: 40, trailing: TVHome.margin)
        #else
        EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        #endif
    }

    #if !os(tvOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            @Bindable var app = app
            Picker("View", selection: $app.settings.libraryViewMode) {
                ForEach(LibraryViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between the poster grid and the Atrium spatial gallery")
        }
        #endif

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                #if os(iOS)
                // A phone has no room beside the title for a segmented control,
                // so one button flips between the two presentations.
                Button {
                    app.settings.libraryViewMode = viewMode == .atrium ? .grid : .atrium
                } label: {
                    Label(
                        viewMode == .atrium ? "Show Grid" : "Show Atrium",
                        systemImage: (viewMode == .atrium ? LibraryViewMode.grid : .atrium).icon)
                }
                #endif

                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(LibraryGridModel.Sort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    Picker("Order", selection: $model.ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                }

                Button {
                    showFilters = true
                } label: {
                    Label(
                        model.activeFilterCount > 0 ? "Filters (\(model.activeFilterCount))" : "Filters",
                        systemImage: model.activeFilterCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
            }
            .onChange(of: model.sort) { Task { await reload() } }
            .onChange(of: model.ascending) { Task { await reload() } }
        }
    }
    #endif
}

/// Grid cell sized by the grid column rather than a fixed width.
struct GridPosterCell: View {
    let item: BaseItem
    @Environment(AppState.self) private var app

    var body: some View {
        #if os(tvOS)
        // Same shape as the home shelf card: the focus engine lifts the poster
        // and the caption stays put beneath it.
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: item) {
                poster
            }
            .buttonStyle(.card)
            caption
                .padding(.horizontal, 4)
        }
        #else
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                poster
                caption
            }
        }
        .buttonStyle(.plain)
        #endif
    }

    private var cornerRadius: CGFloat {
        #if os(tvOS)
        TVHome.cardCornerRadius
        #else
        10
        #endif
    }

    private var poster: some View {
        RemoteImage(url: app.client?.imageURL(item.posterRef, maxWidth: 400))
            .aspectRatio(2 / 3, contentMode: .fill)
            .overlay(alignment: .bottom) {
                if let progress = item.progressFraction {
                    ProgressBar(fraction: progress)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let count = item.userData?.unplayedItemCount, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.blue, in: Capsule())
                        .padding(6)
                } else if item.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .blue)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.posterSubtitle ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
