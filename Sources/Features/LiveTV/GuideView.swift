import SwiftUI

/// Live TV guide, laid out to `Design/reference/GUIDE_SPEC.md`:
/// a large channel logo, then a 16:9 card for what is on now, then the time
/// grid running left to right. The first two columns are frozen; the grid
/// scrolls under a time ruler glued to it.
///
/// Nothing in this view's body reads where the grid is scrolled. The offset
/// lives in `GuideScrollState`, and only small leaf views read it, so a scroll
/// moves the guide without rebuilding it. Off the TV the frozen columns and
/// the ruler sit inside the scroll view, pinned at render time, and move in
/// the same frame as the lanes they label. On the TV they stay outside it,
/// where the focus engine's handling of them is known to work, and follow it.
struct GuideView: View {
    /// When set, channel selection calls this instead of starting playback
    /// directly (used by the in-player guide for channel surfing).
    var onChannelSelected: ((BaseItem) -> Void)?

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @Environment(GuideModel.self) private var guide

    @State private var scroll = GuideScrollState(laneInset: GuideView.laneInset)
    @State private var pendingSwitch: PendingSwitch?
    @State private var didInitialJump = false
    /// The guide's clock, to the minute. It lights the airing cells and places
    /// the now-marker; it ticks on its own, and nothing else redraws for time.
    @State private var minute = GuideView.minuteFloor(GuideClock.now)
    #if os(tvOS)
    /// Which grid cell the remote is on, by segment id. Only so the guide can
    /// open with focus on what is airing now on the first channel rather than
    /// wherever the focus engine's top-left search happens to land (the day
    /// pill); after that the engine drives it.
    @FocusState private var focusedCell: String?
    /// Which frozen cell (logo or Now Playing) has focus, by channel id. The
    /// frozen column does not scroll itself — it is offset to follow the grid
    /// and clipped — so a row above or below the viewport is still a real
    /// focus target the engine will happily move to, and once there nothing
    /// would bring it on screen. Watching this is how the grid is told to.
    @FocusState private var focusedFrozen: String?
    /// Which header control — day pill or a pager step — has focus. Held only
    /// so the focus-preview flag can photograph them; the engine drives them.
    @FocusState private var focusedHeader: GuideHeaderControl?
    /// Handed in by the screen that owns the guide/channel-list switch, drawn
    /// in the header strip on the TV. See `LiveTVView`.
    var headerAccessory: AnyView?
    /// In-player guide: open with focus (and the grid scrolled) on this
    /// channel's airing-now cell instead of the first row's, so a viewer
    /// tuned to channel 411 does not land on A&E. See `PlayerOverlayView`.
    var initialChannelId: String?
    /// The channel to open on: the player's, or the harness's stand-in for it.
    private var openingChannelId: String? {
        #if DEBUG
        if let id = GuideAutopilot.initialChannel { return id }
        #endif
        return initialChannelId
    }
    /// In-player guide: paint no page colour so the stream stays visible
    /// through the scrim the player lays underneath. See `PlayerOverlayView`.
    var transparentBackground = false
    /// Row the grid is asked to show on tvOS 17, which has no `ScrollPosition`:
    /// `scrollPosition(id:)`, made for lazy stacks, is the one jump it has.
    @State private var scrollRowId: String?
    @State private var didSeedFocus = false
    #endif

    struct PendingSwitch: Identifiable {
        var channel: BaseItem
        var program: BaseItem
        var id: String { program.id }
    }

    /// What the frozen columns and the pinned header cover of the scroll view.
    /// Off the TV they live inside it; on the TV they sit outside.
    private static var laneInset: CGSize {
        #if os(tvOS)
        .zero
        #else
        CGSize(width: GuideMetrics.frozenWidth,
               height: GuideMetrics.headerStripHeight + GuideMetrics.gap)
        #endif
    }

    private static func minuteFloor(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    private var totalMinutes: Double { guide.windowEnd.timeIntervalSince(guide.windowStart) / 60 }
    private var contentWidth: CGFloat { CGFloat(totalMinutes) * GuideMetrics.widthPerMinute }

    private var playingChannelId: String? {
        player.isLive ? player.currentItemId : nil
    }

    private var rows: [GuideModel.Row] {
        guide.rows(
            collapsedGroups: app.settings.collapsedGroups,
            searchTerm: "",
            playingChannelId: playingChannelId)
    }

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("guide")
        #endif
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
        .background(pageBackground)
        .overlay(alignment: .bottomTrailing) {
            if guide.refreshError != nil, !guide.channels.isEmpty {
                Button("Listings couldn’t refresh · Retry") { Task { await reload() } }
                    .font(.caption)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
        .task(id: app.client.map { $0.serverURL.absoluteString + "|" + ($0.userId ?? "") }) {
            #if DEBUG
            GuideAutopilot.reportFlags()
            if GuideAutopilot.usesFixture {
                guide.loadFixture()
                #if os(macOS)
                GuideAutopilot.reportRect()
                #endif
                return
            }
            #endif
            guard let client = app.client else { return }
            await guide.ensureFresh(client: client, settings: app.settings)
            #if DEBUG && os(macOS)
            GuideAutopilot.reportRect()
            #endif
        }
        .task { await tickClock() }
        #if DEBUG
        .task(id: guide.status) {
            guard guide.status == .loaded, let target = GuideAutopilot.scrollTarget else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            scroll.scroll(to: target, duration: 0)
        }
        #endif
        #if os(tvOS)
        .task(id: guide.status) {
            // `defaultFocus` is evaluated when the guide first appears, which
            // is before its rows exist; when they do, the engine has already
            // settled somewhere else. Ask again once the cells are laid out.
            // Rows exist as soon as the channels do — programme loading for a
            // large lineup runs for tens of seconds and must not hold focus
            // hostage — but seed only once, so the viewer's own moves stick.
            guard guide.status == .loaded || guide.status == .loadingPrograms, !didSeedFocus else { return }
            didSeedFocus = true
            try? await Task.sleep(for: .milliseconds(350))
            #if DEBUG
            if let target = GuideAutopilot.focusTarget {
                applyFocusPreview(target, rows: rows)
                return
            }
            #endif
            if let initialChannelId = openingChannelId,
               rows.contains(where: { $0.id == "channel-\(initialChannelId)" }) {
                // The tuned channel is usually far down the grid, where the
                // lazy stack has built no cell to focus. The initial jump in
                // `tvGrid` brings its buffered frozen card into the viewport
                // before this focus request.
                focusedFrozen = "now:\(initialChannelId)"
            } else if let id = initialFocusId(rows: rows) {
                focusedCell = id
            }
        }
        #endif
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

    private var pageBackground: Color {
        #if os(tvOS)
        transparentBackground ? Color.clear : GuidePalette.page
        #else
        GuidePalette.page
        #endif
    }

    private func reload() async {
        guard let client = app.client else { return }
        await guide.fetch(client: client, settings: app.settings)
    }

    /// Advance `minute` on the minute. The pinned screenshot clock never moves,
    /// so under the harness this sleeps and changes nothing.
    private func tickClock() async {
        while !Task.isCancelled {
            let now = GuideClock.now
            let next = Self.minuteFloor(now).addingTimeInterval(60)
            do { try await Task.sleep(for: .seconds(max(next.timeIntervalSince(now), 1))) }
            catch { return }
            let current = Self.minuteFloor(GuideClock.now)
            if current != minute { minute = current }
        }
    }

    private func programDialogMessage(_ pending: PendingSwitch) -> String {
        var line = pending.program.name ?? "Program"
        if let start = pending.program.startDate {
            line += " starts at \(GuideTime.label(for: start, style: .compact))"
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

    // MARK: - Assembly

    @ViewBuilder
    private var grid: some View {
        let rows = rows
        let heights = rows.map(\.height)
        #if os(tvOS)
        tvGrid(rows: rows, heights: heights)
        #else
        deskGrid(rows: rows, heights: heights)
        #endif
    }

    /// Hours in the window, and the scroll position the "Now" jump lands on:
    /// 30 minutes before now, clamped.
    private var hourCount: Int {
        max(Int(totalMinutes / 60), 1)
    }

    private var nowJumpX: CGFloat {
        let minutes = GuideClock.now.timeIntervalSince(guide.windowStart) / 60 - 30
        return min(max(0, CGFloat(minutes) * GuideMetrics.widthPerMinute), contentWidth - 1)
    }

    /// Where a page step lands: whole viewports of whole hours, from the hour
    /// the grid is on, so the ruler's labels line up with the left edge.
    private func pageTarget(_ delta: Int) -> Int {
        let hours = max(Int(scroll.laneViewport.width / (60 * GuideMetrics.widthPerMinute)), 1)
        return min(max(scroll.hour + delta * hours, 0), hourCount - 1)
    }

    /// The group headers above the first channel row. The now-marker spans the
    /// channel rows, not the whole stack: with lineup groups collapsed at the
    /// top of the list it otherwise painted red across the group headers and
    /// ended in mid-air above the first cell.
    private func leadingHeaders(_ rows: [GuideModel.Row]) -> Set<String> {
        Set(rows.prefix { if case .channel = $0 { false } else { true } }.map(\.id))
    }

    // MARK: - Mac and iPad

    #if !os(tvOS)
    /// One scroll view holding everything: the ruler is its pinned section
    /// header, the frozen columns ride at the leading edge of every row. Both
    /// are laid out with the lanes, so they move in the same frame as them and
    /// cannot drift a frame behind.
    private func deskGrid(rows: [GuideModel.Row], heights: [CGFloat]) -> some View {
        let rowsHeight = heights.reduce(0, +)
        let unmarked = leadingHeaders(rows)
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            deskRow(row, marked: !unmarked.contains(row.id))
                        }
                    } header: {
                        deskHeader(proxy: proxy, rowsHeight: rowsHeight)
                    }
                }
                .frame(width: GuideMetrics.frozenWidth + contentWidth, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if #unavailable(iOS 18.0, macOS 15.0) {
                        legacyAnchors(height: GuideScrollState.headerHeight + rowsHeight)
                    }
                }
                .background {
                    // Legacy offset tracking for OSes without
                    // onScrollGeometryChange. AppKit does not reliably fire
                    // these during scrolling; it is only the fallback.
                    if #unavailable(iOS 18.0, macOS 15.0) {
                        legacyOffsetReader
                    }
                }
            }
            // .never, not .hidden: on macOS .hidden is only a hint and
            // AppKit still draws the overlay scroller, which is then the
            // brightest thing in the frame after the titles.
            .scrollIndicators(.never)
            #if DEBUG
            .modifier(benchHook(rowsHeight: rowsHeight))
            #endif
            .modifier(GuideAxisScrollGate(state: scroll))
            .modifier(GuideScrollSync(state: scroll) { guide.holdListingUpdates($0) })
            .modifier(GuideLegacyScrollSync(state: scroll))
            .overlay(alignment: .topTrailing) {
                GuidePager(scroll: scroll, hourCount: hourCount) { delta in
                    page(delta, proxy: proxy)
                }
                .frame(height: GuideMetrics.headerStripHeight)
            }
            .background {
                GuideVisibleLoader(
                    rows: rows, heights: heights, scroll: scroll,
                    windowStart: guide.windowStart, windowEnd: guide.windowEnd)
            }
            .onAppear {
                guard !didInitialJump else { return }
                didInitialJump = true
                if #available(iOS 18.0, macOS 15.0, *) {
                    scroll.scroll(.horizontal, to: nowJumpX, duration: 0)
                } else {
                    proxy.scrollTo("guide-now-anchor", anchor: UnitPoint(x: 0, y: 0))
                }
            }
        }
        .padding(.leading, GuideMetrics.contentLeftInset)
        .padding(.top, GuideMetrics.contentTopInset)
    }

    /// The pinned header: the day pill and "Now Playing" held at the leading
    /// edge, the ruler laid out over the lanes it labels.
    private func deskHeader(proxy: ScrollViewProxy, rowsHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            GuideRulerLane(
                labels: GuideRulerLabel.labels(from: guide.windowStart, to: guide.windowEnd),
                contentWidth: contentWidth,
                trailingReserve: GuideHeader.pagerWidth + GuideMetrics.gap)
                .padding(.leading, GuideMetrics.frozenWidth)
            HStack(spacing: GuideMetrics.gap) {
                GuideDayPill(windowStart: guide.windowStart) {
                    jumpToNow(proxy: proxy, rowsHeight: rowsHeight)
                }
                GuideNowPlayingHeading()
            }
            .frame(width: GuideMetrics.frozenWidth, height: GuideMetrics.headerStripHeight, alignment: .leading)
            .background(GuidePalette.page)
            .guidePinnedLeading()
        }
        .frame(height: GuideScrollState.headerHeight, alignment: .top)
        .background(GuidePalette.page)
    }

    /// A row: its lane, and its frozen cells pinned over the lane's leading
    /// end on a page-coloured ground the lane scrolls under.
    private func deskRow(_ row: GuideModel.Row, marked: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            lane(for: row, marked: marked)
                .padding(.leading, GuideMetrics.frozenWidth)
            frozenCells(for: row)
                .frame(width: GuideMetrics.frozenWidth, height: row.height, alignment: .topLeading)
                .background(GuidePalette.page)
                .guidePinnedLeading()
        }
    }

    private func page(_ delta: Int, proxy: ScrollViewProxy) {
        let target = pageTarget(delta)
        if #available(iOS 18.0, macOS 15.0, *) {
            scroll.scroll(.horizontal, to: CGFloat(target) * 60 * GuideMetrics.widthPerMinute, duration: 0.28)
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo("guide-hour-\(target)", anchor: UnitPoint(x: 0, y: 0))
            }
        }
    }

    /// Time only: the row being read stays where it is.
    private func jumpToNow(proxy: ScrollViewProxy, rowsHeight: CGFloat) {
        if #available(iOS 18.0, macOS 15.0, *) {
            scroll.scroll(.horizontal, to: nowJumpX, duration: 0.3)
        } else {
            // A single-anchor jump moves both axes; land the anchor at the
            // same fraction of the column as the viewport already is.
            let travel = max(GuideScrollState.headerHeight + rowsHeight - scroll.viewport.height, 1)
            let fraction = min(max(scroll.offset.y / travel, 0), 1)
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("guide-now-anchor", anchor: UnitPoint(x: 0, y: fraction))
            }
        }
    }

    /// Where `ScrollViewReader` can land before `ScrollPosition` (iOS 18,
    /// macOS 15): one anchor per hour for the pager, one for the "Now" jump.
    /// Placed a frozen column's width early, so landing one at the leading
    /// edge puts its time at the lanes' visible start.
    private func legacyAnchors(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: max(height, 1))
                .offset(x: nowJumpX)
                .id("guide-now-anchor")
            ForEach(0..<hourCount, id: \.self) { hour in
                Color.clear
                    .frame(width: 1, height: max(height, 1))
                    .offset(x: CGFloat(hour) * 60 * GuideMetrics.widthPerMinute)
                    .id("guide-hour-\(hour)")
            }
        }
    }
    #endif

    // MARK: - TV

    #if os(tvOS)
    /// The header strip over two columns: the frozen cells, outside the scroll
    /// view and following it, and the lanes inside it.
    private func tvGrid(rows: [GuideModel.Row], heights: [CGFloat]) -> some View {
        let rowsHeight = heights.reduce(0, +)
        let unmarked = leadingHeaders(rows)
        return VStack(alignment: .leading, spacing: GuideMetrics.gap) {
            GuideHeaderStrip(
                windowStart: guide.windowStart,
                windowEnd: guide.windowEnd,
                contentWidth: contentWidth,
                scroll: scroll,
                hourCount: hourCount,
                onPage: { delta in
                    scroll.scroll(.horizontal, to: CGFloat(pageTarget(delta)) * 60 * GuideMetrics.widthPerMinute,
                                  duration: 0.28)
                },
                onJumpToNow: {
                    // Time only: the row being read stays under the remote.
                    scroll.scroll(.horizontal, to: nowJumpX, duration: 0.3)
                })
                .headerFocusScope($focusedHeader)
            HStack(spacing: GuideMetrics.gap) {
                GuideFrozenColumn(heights: heights, scroll: scroll) { range in
                    ForEach(rows[range]) { row in
                        frozenCells(for: row)
                    }
                }
                .frame(width: GuideMetrics.frozenWidth - GuideMetrics.gap)
                .clipped()
                .background {
                    GuideVisibleLoader(
                        rows: rows, heights: heights, scroll: scroll,
                        windowStart: guide.windowStart, windowEnd: guide.windowEnd)
                }

                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            lane(for: row, marked: !unmarked.contains(row.id))
                        }
                    }
                    .scrollTargetLayout()
                    .frame(width: contentWidth, alignment: .topLeading)
                    .background {
                        if #unavailable(tvOS 18.0) {
                            legacyOffsetReader
                        }
                    }
                }
                .scrollIndicators(.never)
                #if DEBUG
                .modifier(benchHook(rowsHeight: rowsHeight))
                #endif
                .modifier(GuideAxisScrollGate(state: scroll, rowId: $scrollRowId))
                .overlay(alignment: .trailing) {
                    // The grid runs to the screen's edge, so the last cell is
                    // almost always a partial one. Faded into the page over
                    // the overscan margin rather than cut: a hard edge at the
                    // bezel reads as the guide ending there, a fade as it
                    // continuing.
                    LinearGradient(
                        colors: [.clear, GuidePalette.page],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: GuideMetrics.trailingFade)
                        .allowsHitTesting(false)
                }
                .modifier(GuideScrollSync(state: scroll) { guide.holdListingUpdates($0) })
                .modifier(GuideLegacyScrollSync(state: scroll))
                .task {
                    guard !didInitialJump else { return }
                    didInitialJump = true
                    // After the first layout has settled, not in it: see
                    // `GuideScrollState.scroll(to:duration:)`. The focus seed
                    // waits longer still, so this lands first.
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    if let initialChannelId = openingChannelId,
                       rows.contains(where: { $0.id == "channel-\(initialChannelId)" }) {
                        // In-player: open on the tuned channel's row, a little
                        // below the top so the rows a surf heads for are in
                        // view too, instead of on the first channel of the day.
                        let rowId = "channel-\(initialChannelId)"
                        scrollRowId = rowId
                        let top = rows.prefix(while: { $0.id != rowId }).reduce(0) { $0 + $1.height }
                        scroll.scroll(.vertical, to: max(top - scroll.viewport.height * 0.15, 0), duration: 0)
                        return
                    }
                    scroll.scroll(.horizontal, to: nowJumpX, duration: 0)
                }
                .onChange(of: focusedFrozen) { _, focused in
                    // "logo:<channel>" and "now:<channel>" are both the
                    // channel's row; "group:<name>" is the header's own.
                    let parts = (focused ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    reveal(
                        rowId: parts[0] == "group" ? "header-\(parts[1])" : "channel-\(parts[1])",
                        rows: self.rows)
                }
            }
            // Exactly the five rows the density arithmetic allows (see
            // `contentTopInset`): left to fill the screen, the sixth row's
            // top 17 points showed as a sliver under the fifth.
            .frame(
                height: GuideMetrics.rowPitch * GuideMetrics.visibleRows - GuideMetrics.gap,
                alignment: .top)
            // The frame alone did not do it: a scroll view whose bottom
            // lies inside the screen's overscan margin keeps painting its
            // content down into it, and the sixth row's top edge showed
            // through under the fifth. Clip.
            .clipped()
        }
        .padding(.leading, GuideMetrics.contentLeftInset)
        .padding(.top, GuideMetrics.contentTopInset)
        // The mode switch, in the tab bar's own band. Attached *before*
        // `ignoresSafeArea` so it shares the guide's screen-relative frame;
        // an overlay added after it is inset by the safe area again and
        // landed on the first row of cells.
        .overlay(alignment: .topTrailing) {
            if let headerAccessory {
                headerAccessory
                    .padding(.top, GuideMetrics.tabBarBandTop)
                    .padding(.trailing, GuideMetrics.contentLeftInset)
            }
        }
        // Laid out against the screen, not the safe area. The safe area the
        // tab bar hands down starts at 157 — a whole row pitch of black between
        // the bar and the header — and its 80-point sides put the left inset
        // at 191 where the spec scales to 110, while the grid's right edge
        // hard-clipped at the screen anyway. `GuideMetrics.contentTopInset`
        // carries the numbers. (The bottom was already ignored: the frozen
        // column is a plain view and was clipped 60 points above the scroll
        // view beside it.)
        .ignoresSafeArea()
        .defaultFocus($focusedCell, initialFocusId(rows: rows))
    }

    /// The airing-now cell of the first channel row: what a viewer opening a
    /// guide wants to know first, and the cell the now-marker runs through.
    ///
    /// When nothing is airing the lane still has a cell under the marker — an
    /// off-air or no-listings filler — and that is the target; returning nil
    /// left focus on the tab bar, with the guide open and no cell lit.
    private func initialFocusId(rows: [GuideModel.Row]) -> String? {
        let channels = rows.compactMap { row -> BaseItem? in
            if case .channel(let channel) = row { channel } else { nil }
        }
        // The tuned channel first when the player asked for it, then the top row.
        let ordered = (channels.first { $0.id == openingChannelId }.map { [$0] } ?? []) + channels
        for channel in ordered {
            let programs = guide.listings(for: channel.id).programs
            if let airing = programs.first(where: { program in
                guard let start = program.startDate, let end = program.endDate else { return false }
                return start <= GuideClock.now && GuideClock.now < end
            }) {
                return airing.id
            }
            return GuideProgramRow.segments(
                channel: channel, programs: programs,
                windowStart: guide.windowStart, windowEnd: guide.windowEnd, now: GuideClock.now)
                .first(where: \.isAiring)?.id
        }
        return nil
    }

    /// The frozen cards and the two-axis scroll view are separate focus
    /// containers. UIKit's geometric search can strand a card even when its
    /// neighbour is visibly beside it. Name the destination for remote moves.
    private func moveFromFrozen(_ direction: MoveCommandDirection, channel: BaseItem, isLogo: Bool) {
        switch direction {
        case .left:
            if !isLogo { focusFrozen("logo:\(channel.id)") }
        case .right:
            if isLogo { focusFrozen("now:\(channel.id)") }
            else {
                let segments = segments(for: channel)
                if let target = segments.first(where: { $0.x + $0.width > scroll.heading.x }) {
                    focusProgram(target, channel: channel)
                }
            }
        case .up, .down:
            moveVertically(direction, channel: channel, frozenPrefix: isLogo ? "logo:" : "now:")
        default: break
        }
    }

    private func moveFromProgram(_ direction: MoveCommandDirection, channel: BaseItem, sourceId: String) {
        let segments = segments(for: channel)
        guard let index = segments.firstIndex(where: { $0.id == sourceId }) else { return }
        switch direction {
        case .left:
            if index == 0 { focusFrozen("now:\(channel.id)") }
            else { focusProgram(segments[index - 1], channel: channel) }
        case .right:
            if index + 1 < segments.count { focusProgram(segments[index + 1], channel: channel) }
        case .up, .down:
            moveVertically(direction, channel: channel, frozenPrefix: nil,
                           timeX: max(segments[index].x, scroll.heading.x))
        default: break
        }
    }

    private func segments(for channel: BaseItem) -> [GuideProgramRow.Segment] {
        GuideProgramRow.segments(channel: channel, programs: guide.listings(for: channel.id).programs,
            windowStart: guide.windowStart, windowEnd: guide.windowEnd, now: GuideClock.now)
    }

    private func focusFrozen(_ id: String) {
        focusedCell = nil
        focusedFrozen = id
    }

    private func focusProgram(_ target: GuideProgramRow.Segment, channel: BaseItem) {
        focusedFrozen = nil
        reveal(rowId: "channel-\(channel.id)", rows: rows)
        let left = scroll.heading.x
        let width = scroll.laneViewport.width
        if target.x + target.width <= left || target.x >= left + width {
            // Instant, not animated: focus is handed over in the same breath,
            // and a cell still off screen when it asks does not take it.
            scroll.scroll(.horizontal, to: min(target.x, max(0, contentWidth - width)), duration: 0)
        }
        focusedCell = target.id
    }

    private func moveVertically(_ direction: MoveCommandDirection, channel: BaseItem,
                                frozenPrefix: String?, timeX: CGFloat = 0) {
        let rows = rows
        guard let index = rows.firstIndex(where: { $0.id == "channel-\(channel.id)" }) else { return }
        let next = index + (direction == .up ? -1 : 1)
        guard rows.indices.contains(next) else {
            if direction == .up { focusedCell = nil; focusedFrozen = nil; focusedHeader = .dayPill }
            return
        }
        switch rows[next] {
        case .header(let group, _, _):
            focusFrozen("group:\(group)")
        case .channel(let channel):
            reveal(rowId: "channel-\(channel.id)", rows: rows)
            if let frozenPrefix { focusFrozen(frozenPrefix + channel.id) }
            else if let target = segments(for: channel).first(where: { $0.x + $0.width > timeX }) {
                focusProgram(target, channel: channel)
            }
        }
    }

    /// Bring a channel row into the grid when one of its cells takes focus.
    ///
    /// The logo and Now Playing columns are not a scroll view — they are laid
    /// out whole and offset to follow the grid — so every channel's pair is a
    /// live focus target even when it is clipped off the top or the bottom,
    /// and nothing follows the remote there on its own. This is what follows
    /// it.
    ///
    /// Measured against where the grid is headed, not where it is mid-glide:
    /// only fired when the row is genuinely outside that band, so stepping
    /// through rows that are already on screen does not re-seat the grid under
    /// the viewer at every press, and the minimal move puts the row wholly in
    /// the band — one row's worth, so walking the column steps rather than
    /// re-seats the guide.
    private func reveal(rowId: String, rows: [GuideModel.Row]) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }) else { return }
        let height = scroll.laneViewport.height
        guard height > 0 else { return }
        let top = rows.prefix(index).reduce(0) { $0 + $1.height }
        let bottom = top + rows[index].height
        let bandTop = scroll.heading.y
        let target: CGFloat
        if top < bandTop {
            target = top
        } else if bottom > bandTop + height {
            target = bottom - height
        } else {
            return
        }
        scrollRowId = rowId
        scroll.scroll(.vertical, to: max(target, 0), duration: 0.2)
    }

    #if DEBUG
    /// Move focus where `-GuideFocus` asks, so the harness can photograph a
    /// focus state the simulator has no remote to reach. Rows count channel
    /// rows only (group headers are skipped); columns count a lane's cells in
    /// time order, fillers included, the same walk the remote makes.
    private func applyFocusPreview(_ target: GuideAutopilot.FocusTarget, rows: [GuideModel.Row]) {
        let channels = rows.compactMap { row -> BaseItem? in
            if case .channel(let channel) = row { channel } else { nil }
        }
        switch target {
        case .dayPill: focusedHeader = .dayPill
        case .pageBack: focusedHeader = .pageBack
        case .pageForward: focusedHeader = .pageForward
        case .modeSwitch: break // the switch focuses itself; see GuideModeSwitch
        case .logo(let row):
            guard channels.indices.contains(row) else { return }
            focusedFrozen = "logo:\(channels[row].id)"
        case .nowPlaying(let row):
            guard channels.indices.contains(row) else { return }
            focusedFrozen = "now:\(channels[row].id)"
        case .cell(let row, let column):
            guard channels.indices.contains(row) else { return }
            let segments = segments(for: channels[row])
            guard segments.indices.contains(column) else { return }
            focusProgram(segments[column], channel: channels[row])
        }
    }
    #endif
    #endif

    // MARK: - Rows

    @ViewBuilder
    private func frozenCells(for row: GuideModel.Row) -> some View {
        switch row {
        case .header(let group, let count, let collapsed):
            GuideGroupHeaderCell(group: group, count: count, collapsed: collapsed) {
                toggleGroup(group)
            }
            #if os(tvOS)
            .focused($focusedFrozen, equals: "group:\(group)")
            #endif
            .frame(
                width: GuideMetrics.frozenWidth - GuideMetrics.gap,
                height: GuideMetrics.groupHeaderHeight,
                alignment: .leading)
        case .channel(let channel):
            let cells = GuideFrozenCells(
                channel: channel,
                listings: guide.listings(for: channel.id),
                isPlaying: channel.id == playingChannelId,
                now: minute,
                onSelect: {
                    #if DEBUG
                    GuideAutopilot.reportTap("frozen", channel.id)
                    #endif
                    select(channel: channel)
                })
            #if os(tvOS)
            cells.focus(through: $focusedFrozen) { direction, isLogo in
                moveFromFrozen(direction, channel: channel, isLogo: isLogo)
            }
            .equatable()
            #else
            cells.equatable()
            #endif
        }
    }

    @ViewBuilder
    private func lane(for row: GuideModel.Row, marked: Bool) -> some View {
        switch row {
        case .header:
            Color.clear
                .frame(width: contentWidth, height: GuideMetrics.groupHeaderHeight)
                .overlay(alignment: .topLeading) {
                    if marked {
                        GuideNowMarker(
                            windowStart: guide.windowStart, now: minute,
                            width: contentWidth, height: GuideMetrics.groupHeaderHeight)
                    }
                }
        case .channel(let channel):
            GuideLaneSpan(scroll: scroll) { span, column in
                programRow(channel: channel, span: span, column: column)
            }
        }
    }

    private func programRow(channel: BaseItem, span: Range<CGFloat>, column: Int) -> some View {
        let row = GuideProgramRow(
            channel: channel,
            listings: guide.listings(for: channel.id),
            windowStart: guide.windowStart,
            windowEnd: guide.windowEnd,
            width: contentWidth,
            now: minute,
            span: span,
            onSelect: { program in
                #if DEBUG
                GuideAutopilot.reportTap("lane", channel.id)
                #endif
                if let program {
                    handleProgramTap(program: program, channel: channel)
                } else {
                    select(channel: channel)
                }
            })
        #if os(tvOS)
        return row
            .focusScope(cellFocus: $focusedCell)
            .pinned(to: scroll, column: column)
            .moveCommands { direction, sourceId in
                moveFromProgram(direction, channel: channel, sourceId: sourceId)
            }
            .equatable()
        #else
        return row.equatable()
        #endif
    }

    private func handleProgramTap(program: BaseItem, channel: BaseItem) {
        if let start = program.startDate, start > GuideClock.now {
            pendingSwitch = PendingSwitch(channel: channel, program: program)
        } else {
            select(channel: channel)
        }
    }

    private func toggleGroup(_ group: String) {
        if let index = app.settings.collapsedGroups.firstIndex(of: group) {
            app.settings.collapsedGroups.remove(at: index)
        } else {
            app.settings.collapsedGroups.append(group)
        }
    }

    // MARK: - Scroll plumbing

    /// Content offset by preference, for OSes without onScrollGeometryChange.
    private var legacyOffsetReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: GuideScrollOffsetKey.self,
                value: CGPoint(
                    x: -geometry.frame(in: .named("guideScroll")).minX,
                    y: -geometry.frame(in: .named("guideScroll")).minY))
        }
    }

    #if DEBUG
    private func benchHook(rowsHeight: CGFloat) -> GuideBenchHook {
        GuideBenchHook(
            rowPitch: GuideMetrics.rowPitch,
            page: 60 * GuideMetrics.widthPerMinute,
            limit: {
                CGSize(width: contentWidth - scroll.laneViewport.width,
                       height: rowsHeight - scroll.laneViewport.height)
            },
            scroll: { point, duration in scroll.scroll(to: point, duration: duration) })
    }
    #endif
}

extension GuideScrollState {
    /// The pinned header's height off the TV: the strip, and the gap under it.
    static var headerHeight: CGFloat {
        GuideMetrics.headerStripHeight + GuideMetrics.gap
    }
}

/// Before onScrollGeometryChange: the content's offset arrives by preference,
/// its viewport from a reader behind the scroll view.
private struct GuideLegacyScrollSync: ViewModifier {
    let state: GuideScrollState

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content
        } else {
            content
                .coordinateSpace(name: "guideScroll")
                .onPreferenceChange(GuideScrollOffsetKey.self) { value in
                    state.update(offset: value)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { state.update(viewport: geometry.size) }
                            .onChange(of: geometry.size) { _, size in state.update(viewport: size) }
                    }
                }
        }
    }
}

#if os(tvOS)
/// The TV's frozen column: every channel's logo and card, laid out whole and
/// offset to follow the grid's scroll.
///
/// The only part of the TV guide that reads the offset per frame, and a leaf:
/// a scroll moves this stack and rebuilds nothing in it, because the cells are
/// equatable on what they draw. Only artwork near the viewport is built —
/// spacers above and below hold every row's exact position.
private struct GuideFrozenColumn<Cells: View>: View {
    let heights: [CGFloat]
    let scroll: GuideScrollState
    @ViewBuilder let cells: (Range<Int>) -> Cells

    var body: some View {
        let offset = scroll.offset.y
        let height = scroll.viewport.height
        let visible = GuideViewport(
            heights: heights, offset: offset,
            height: height > 0 ? height : GuideMetrics.rowPitch * 8,
            buffer: GuideMetrics.rowPitch * 3)
        Color.clear
            .overlay(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: visible.top)
                    cells(visible.range)
                    Color.clear.frame(height: visible.bottom)
                }
                .offset(y: -offset)
            }
    }
}

extension GuideFrozenCells {
    /// The guide's frozen-focus binding and its move handler, threaded in after
    /// construction so the initialiser stays platform-neutral.
    func focus(
        through binding: FocusState<String?>.Binding,
        onMove: @escaping (MoveCommandDirection, Bool) -> Void
    ) -> GuideFrozenCells {
        var cells = self
        cells.focus = binding
        cells.onMove = onMove
        return cells
    }
}
#endif

/// Fetches listings for what is on screen ahead of the background load.
///
/// Keyed on the grid's row band and column rather than its offset, so it
/// rebuilds a few times a second at most while the grid moves, and its task
/// restarts only when the set of channels or hours on screen changes.
private struct GuideVisibleLoader: View {
    let rows: [GuideModel.Row]
    let heights: [CGFloat]
    let scroll: GuideScrollState
    let windowStart: Date
    let windowEnd: Date

    @Environment(AppState.self) private var app
    @Environment(GuideModel.self) private var guide

    private struct Request: Equatable {
        var channelIds: [String]
        var from: Date
        var to: Date
    }

    var body: some View {
        let pitch = GuideMetrics.rowPitch
        let size = scroll.laneViewport
        // The band is the offset to within a row; a row of slack covers it.
        let visible = GuideViewport(
            heights: heights, offset: CGFloat(scroll.rowBand) * pitch,
            height: (size.height > 0 ? size.height : pitch * 8) + pitch,
            buffer: pitch * 3)
        let block: TimeInterval = 2 * 3600
        let blockWidth = GuideMetrics.widthPerMinute * 120
        let left = CGFloat(scroll.column) * GuideMetrics.columnWidth
        let from = windowStart.addingTimeInterval(floor(left / blockWidth) * block)
        let end = windowStart.addingTimeInterval(
            max(1, ceil((left + GuideMetrics.columnWidth + size.width) / blockWidth)) * block)
        let request = Request(
            channelIds: rows[visible.range].compactMap { row in
                if case .channel(let channel) = row { return channel.id }
                return nil
            },
            from: from, to: min(windowEnd, end))
        Color.clear
            .task(id: request) {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
                guard let client = app.client else { return }
                await guide.loadVisiblePrograms(client: client, channelIds: request.channelIds,
                                                from: request.from, to: request.to)
            }
    }
}

// MARK: - Timeline header

enum GuideTime {
    enum Style { case hour, exact, compact }

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

    /// "9:00AM" — the reference's ruler runs the meridiem straight onto the
    /// time, which is what lets a label sit inside a 30-minute tick.
    static let compactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }()

    static func label(for date: Date, style: Style) -> String {
        switch style {
        case .hour: hourFormatter.string(from: date)
        case .exact: exactFormatter.string(from: date)
        case .compact: compactFormatter.string(from: date)
        }
    }
}
