import SwiftUI

/// Xfinity-style TV guide: frozen channel column, horizontally scrolling
/// program grid with a synced timeline header, collapsible lineup groups,
/// and a now-marker. Layout mirrors the Fladder fork's live_tv_guide.dart.
struct GuideView: View {
    /// When set, channel selection calls this instead of starting playback
    /// directly (used by the in-player guide for channel surfing).
    var onChannelSelected: ((BaseItem) -> Void)?

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @Environment(GuideModel.self) private var guide
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var scrollOffset: CGPoint = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var searchText = ""
    @State private var pendingSwitch: PendingSwitch?
    @State private var didInitialJump = false

    struct PendingSwitch: Identifiable {
        var channel: BaseItem
        var program: BaseItem
        var id: String { program.id }
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var leftWidth: CGFloat { GuideMetrics.leftColumnWidth(compact: isCompact) }
    private var totalMinutes: Double { guide.windowEnd.timeIntervalSince(guide.windowStart) / 60 }
    private var contentWidth: CGFloat { CGFloat(totalMinutes) * GuideMetrics.widthPerMinute }

    private var playingChannelId: String? {
        player.isLive ? player.currentItemId : nil
    }

    private var rows: [GuideModel.Row] {
        guide.rows(
            collapsedGroups: app.settings.collapsedGroups,
            searchTerm: searchText,
            playingChannelId: playingChannelId)
    }

    var body: some View {
        Group {
            switch guide.status {
            case .idle, .loadingChannels:
                CenteredProgressView()
            case .error(let message):
                ErrorRetryView(message: message) {
                    Task { await reload() }
                }
            case .loadingPrograms, .loaded:
                grid
            }
        }
        .task {
            guard let client = app.client else { return }
            await guide.ensureFresh(client: client, settings: app.settings)
        }
        .confirmationDialog(
            "Switch channel?",
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { pending in
            Button("Watch \(pending.channel.displayTitle)") {
                select(channel: pending.channel)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(programDialogMessage(pending))
        }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await guide.fetch(client: client, settings: app.settings)
    }

    private func programDialogMessage(_ pending: PendingSwitch) -> String {
        var line = pending.program.name ?? "Program"
        if let start = pending.program.startDate {
            line += " starts at \(GuideTime.label(for: start, style: .exact))"
        }
        return line
    }

    private func select(channel: BaseItem) {
        if let onChannelSelected {
            onChannelSelected(channel)
        } else if let client = app.client {
            player.playChannel(channel, client: client, settings: app.settings)
        }
    }

    // MARK: - Grid assembly

    private var rowsHeight: CGFloat {
        rows.reduce(0) { $0 + $1.height }
    }

    private var grid: some View {
        let rows = rows
        let rowsHeight = rows.reduce(0) { $0 + $1.height }
        return VStack(spacing: 0) {
            controls
            Divider()
            headerStrip
            Divider()
            gridBody(rows: rows, rowsHeight: rowsHeight)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Channel or program", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(maxWidth: 380)

            Spacer()

            if guide.status == .loadingPrograms {
                ProgressView()
                    .controlSize(.small)
            }

            if hasGroups {
                Button {
                    toggleAllGroups()
                } label: {
                    Image(systemName: allCollapsed
                        ? "rectangle.expand.vertical"
                        : "rectangle.compress.vertical")
                }
                .buttonStyle(.plain)
                .help(allCollapsed ? "Expand all groups" : "Collapse all groups")
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh guide")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hasGroups: Bool {
        guide.lineup?.isEmpty == false
    }

    private var allGroupNames: [String] {
        var names = guide.lineup?.groupOrder ?? []
        names.append(GuideModel.otherGroupName)
        return names
    }

    private var allCollapsed: Bool {
        let collapsed = Set(app.settings.collapsedGroups)
        return allGroupNames.allSatisfy { collapsed.contains($0) }
    }

    private func toggleAllGroups() {
        app.settings.collapsedGroups = allCollapsed ? [] : allGroupNames
    }

    private func toggleGroup(_ group: String) {
        if let index = app.settings.collapsedGroups.firstIndex(of: group) {
            app.settings.collapsedGroups.remove(at: index)
        } else {
            app.settings.collapsedGroups.append(group)
        }
    }

    // MARK: - Header strip (fixed vertically, synced horizontally)

    private var headerStrip: some View {
        HStack(spacing: 0) {
            Button {
                jumpRequest &+= 1
            } label: {
                Label("Now", systemImage: "clock")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: leftWidth)

            Color.clear
                .frame(height: GuideMetrics.timelineHeight)
                .overlay(alignment: .topLeading) {
                    TimelineHeader(
                        start: guide.windowStart,
                        end: guide.windowEnd,
                        width: contentWidth)
                        .offset(x: -scrollOffset.x)
                }
                .clipped()
        }
        .frame(height: GuideMetrics.timelineHeight)
    }

    @State private var jumpRequest = 0

    // MARK: - Body (frozen column + 2D grid)

    private func gridBody(rows: [GuideModel.Row], rowsHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Frozen channel column, driven by the grid's vertical offset.
            Color.clear
                .frame(width: leftWidth)
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            leftCell(for: row)
                        }
                    }
                    .offset(y: -scrollOffset.y)
                }
                .clipped()

            Divider()

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            stripCell(for: row)
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .overlay(alignment: .topLeading) {
                        nowLine(height: rowsHeight)
                    }
                    .overlay(alignment: .topLeading) {
                        // Full-height anchor used by the fraction-preserving jump.
                        Color.clear
                            .frame(width: 1, height: max(rowsHeight, 1))
                            .offset(x: nowJumpX)
                            .id("guide-now-anchor")
                    }
                    .background {
                        // Legacy offset tracking: AppKit does not reliably fire
                        // these during scrolling, so this is only the fallback
                        // for OSes without onScrollGeometryChange.
                        if #unavailable(iOS 18.0, macOS 15.0) {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: GuideScrollOffsetKey.self,
                                    value: CGPoint(
                                        x: -geometry.frame(in: .named("guideScroll")).minX,
                                        y: -geometry.frame(in: .named("guideScroll")).minY))
                            }
                        }
                    }
                }
                .coordinateSpace(name: "guideScroll")
                .modifier(GuideScrollSync(
                    onOffset: { scrollOffset = $0 },
                    onViewport: { viewportSize = $0 }))
                .onPreferenceChange(GuideScrollOffsetKey.self) { value in
                    scrollOffset = value
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { viewportSize = geometry.size }
                            .onChange(of: geometry.size) { _, newValue in viewportSize = newValue }
                    }
                }
                .onAppear {
                    guard !didInitialJump else { return }
                    didInitialJump = true
                    proxy.scrollTo("guide-now-anchor", anchor: UnitPoint(x: 0, y: 0))
                }
                .onChange(of: jumpRequest) {
                    let travel = max(rowsHeight - viewportSize.height, 1)
                    let fraction = min(max(scrollOffset.y / travel, 0), 1)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("guide-now-anchor", anchor: UnitPoint(x: 0, y: fraction))
                    }
                }
            }
        }
    }

    /// X position the "Now" jump lands on: 30 minutes before now, clamped.
    private var nowJumpX: CGFloat {
        let minutes = Date().timeIntervalSince(guide.windowStart) / 60 - 30
        return min(max(0, CGFloat(minutes) * GuideMetrics.widthPerMinute), contentWidth - 1)
    }

    private func nowLine(height: CGFloat) -> some View {
        let minutes = Date().timeIntervalSince(guide.windowStart) / 60
        let x = CGFloat(minutes) * GuideMetrics.widthPerMinute
        return Rectangle()
            .fill(.red.opacity(0.8))
            .frame(width: 1.5, height: height)
            .offset(x: min(max(x, 0), contentWidth))
            .allowsHitTesting(false)
    }

    // MARK: - Row cells

    @ViewBuilder
    private func leftCell(for row: GuideModel.Row) -> some View {
        switch row {
        case .header(let group, let count, let collapsed):
            Button {
                toggleGroup(group)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: GuideMetrics.groupHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.6))
        case .channel(let channel):
            Button {
                select(channel: channel)
            } label: {
                ChannelColumnCell(
                    channel: channel,
                    isPlaying: channel.id == playingChannelId,
                    showNumber: app.settings.showChannelNumbers,
                    compact: isCompact)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func stripCell(for row: GuideModel.Row) -> some View {
        switch row {
        case .header:
            Rectangle()
                .fill(.quaternary.opacity(0.6))
                .frame(width: contentWidth, height: GuideMetrics.groupHeaderHeight)
        case .channel(let channel):
            ProgramStrip(
                channel: channel,
                programs: guide.programsByChannel[channel.id] ?? [],
                windowStart: guide.windowStart,
                windowEnd: guide.windowEnd,
                width: contentWidth,
                onSelect: { program in
                    if let program {
                        handleProgramTap(program: program, channel: channel)
                    } else {
                        select(channel: channel)
                    }
                })
        }
    }

    private func handleProgramTap(program: BaseItem, channel: BaseItem) {
        let now = Date()
        if let start = program.startDate, start > now {
            pendingSwitch = PendingSwitch(channel: channel, program: program)
        } else {
            select(channel: channel)
        }
    }
}

struct GuideScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// Live scroll-offset sync for the frozen channel column and timeline header.
/// Uses onScrollGeometryChange where available (fires continuously on both
/// AppKit and UIKit scrolling); older OSes fall back to the preference key.
private struct GuideScrollSync: ViewModifier {
    let onOffset: (CGPoint) -> Void
    let onViewport: (CGSize) -> Void

    struct Snapshot: Equatable {
        var offset: CGPoint
        var viewport: CGSize
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: Snapshot.self) { geometry in
                Snapshot(
                    offset: CGPoint(
                        x: geometry.contentOffset.x + geometry.contentInsets.leading,
                        y: geometry.contentOffset.y + geometry.contentInsets.top),
                    viewport: geometry.containerSize)
            } action: { _, snapshot in
                onOffset(snapshot.offset)
                onViewport(snapshot.viewport)
            }
        } else {
            content
        }
    }
}

// MARK: - Timeline header

enum GuideTime {
    enum Style { case hour, exact }

    static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    static let exactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func label(for date: Date, style: Style) -> String {
        switch style {
        case .hour: hourFormatter.string(from: date)
        case .exact: exactFormatter.string(from: date)
        }
    }
}

struct TimelineHeader: View {
    let start: Date
    let end: Date
    let width: CGFloat

    private var halfHourMarks: [Date] {
        var marks: [Date] = []
        var cursor = start
        while cursor < end {
            marks.append(cursor)
            cursor = cursor.addingTimeInterval(30 * 60)
        }
        return marks
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(halfHourMarks, id: \.timeIntervalSince1970) { mark in
                let minutes = mark.timeIntervalSince(start) / 60
                let x = CGFloat(minutes) * GuideMetrics.widthPerMinute
                let isHour = Calendar.current.component(.minute, from: mark) == 0
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: isHour ? 12 : 7)
                    if isHour {
                        Text(GuideTime.label(for: mark, style: .hour))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .offset(x: x, y: 8)
            }
        }
        .frame(width: width, height: GuideMetrics.timelineHeight, alignment: .topLeading)
    }
}

// MARK: - Channel column cell

struct ChannelColumnCell: View {
    let channel: BaseItem
    let isPlaying: Bool
    let showNumber: Bool
    let compact: Bool

    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            if showNumber {
                Text(channel.displayChannelNumber ?? "")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 30 : 38, alignment: .trailing)
            }
            RemoteImage(
                url: app.client?.imageURL(
                    itemId: channel.id, type: .primary,
                    tag: channel.imageTags?["Primary"], maxHeight: 80),
                contentMode: .fit)
                .frame(width: compact ? 30 : 42, height: 24)
            Text(channel.displayTitle)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "play.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if channel.userData?.isFavorite == true {
                Image(systemName: "heart.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: GuideMetrics.rowHeight)
        .contentShape(Rectangle())
        .background(isPlaying ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Program strip

struct ProgramStrip: View {
    let channel: BaseItem
    let programs: [BaseItem]
    let windowStart: Date
    let windowEnd: Date
    let width: CGFloat
    /// nil program = bare row tap (tune the channel).
    let onSelect: (BaseItem?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: GuideMetrics.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }

            ForEach(programs, id: \.id) { program in
                if let placement = placement(for: program) {
                    ProgramCell(program: program, width: placement.width)
                        .offset(x: placement.x)
                        .onTapGesture { onSelect(program) }
                }
            }
        }
        .frame(width: width, height: GuideMetrics.rowHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func placement(for program: BaseItem) -> (x: CGFloat, width: CGFloat)? {
        guard let start = program.startDate, let end = program.endDate, end > start else { return nil }
        let clampedStart = max(start, windowStart)
        let clampedEnd = min(end, windowEnd)
        guard clampedEnd > clampedStart else { return nil }
        let x = CGFloat(clampedStart.timeIntervalSince(windowStart) / 60) * GuideMetrics.widthPerMinute
        let cellWidth = CGFloat(clampedEnd.timeIntervalSince(clampedStart) / 60) * GuideMetrics.widthPerMinute
        return (x, max(cellWidth - 2, 8))
    }
}

struct ProgramCell: View {
    let program: BaseItem
    let width: CGFloat

    private var isAiring: Bool {
        guard let start = program.startDate, let end = program.endDate else { return false }
        let now = Date()
        return start <= now && now < end
    }

    private var isPast: Bool {
        guard let end = program.endDate else { return false }
        return end <= Date()
    }

    private var accentBar: Color? {
        if program.isSports == true { return .green }
        if program.isMovie == true { return .purple }
        if program.isNews == true { return .blue }
        if program.isKids == true { return .orange }
        return nil
    }

    private var timeLabel: String {
        guard let start = program.startDate, let end = program.endDate else { return "" }
        return "\(GuideTime.label(for: start, style: .exact))–\(GuideTime.label(for: end, style: .exact))"
    }

    var body: some View {
        HStack(spacing: 0) {
            if let accentBar {
                Rectangle()
                    .fill(accentBar.opacity(isPast ? 0.35 : 0.8))
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(program.name ?? "—")
                    .font(.caption.weight(isAiring ? .semibold : .regular))
                    .lineLimit(1)
                if width > 70 {
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: GuideMetrics.rowHeight - 6, alignment: .topLeading)
        .background(
            isAiring ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isAiring ? Color.accentColor.opacity(0.7) : Color.separator.opacity(0.4),
                    lineWidth: isAiring ? 1.2 : 0.5)
        }
        .opacity(isPast ? 0.55 : 1)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private extension Color {
    static var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}
