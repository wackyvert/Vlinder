import SwiftUI

/// One channel's lane in the time grid: its programs placed on the time scale,
/// with the gaps between them filled by the right kind of empty state.
///
/// Equatable, and compared on what it draws: the guide hands every lane fresh
/// closures each time it builds, and closures never compare equal, so without
/// this every visible lane rebuilt whenever anything in the guide did. Its
/// listings arrive through `GuideListings`, which rebuilds it directly.
struct GuideProgramRow: View, Equatable {
    let channel: BaseItem
    let listings: GuideListings
    let windowStart: Date
    let windowEnd: Date
    let width: CGFloat
    /// The guide's clock, to the minute: lights the airing cells and places
    /// the now-marker.
    let now: Date
    /// The stretch of the lane to build, in the lane's own coordinates.
    ///
    /// A lane is sixteen hours — 12,700 points on the TV — and the viewport
    /// shows under two of them; on the TV every cell is a focusable button.
    /// Only cells overlapping this span are built. See `GuideLaneSpan`.
    let span: Range<CGFloat>
    /// nil program = bare lane tap (tune the channel).
    let onSelect: (BaseItem?) -> Void
    #if os(tvOS)
    /// Handed down from the guide so its default-focus rule can name a cell.
    var focusedCell: FocusState<String?>.Binding?
    var onMove: ((MoveCommandDirection, String) -> Void)?
    /// The grid's scroll, for the cells whose titles pin to the lane's visible
    /// left edge as it moves. See `GuideProgramCell.pinnedInset`.
    var scroll: GuideScrollState?
    /// The 30-minute column the visible left edge is in. The lane is rebuilt
    /// when it changes; between rebuilds only the cells that straddle the
    /// column read the edge itself.
    var column = 0
    #endif

    static func == (a: GuideProgramRow, b: GuideProgramRow) -> Bool {
        var same = a.listings === b.listings && a.channel == b.channel
            && a.windowStart == b.windowStart && a.windowEnd == b.windowEnd
            && a.width == b.width && a.now == b.now && a.span == b.span
        #if os(tvOS)
        same = same && a.column == b.column && (a.focusedCell == nil) == (b.focusedCell == nil)
            && a.scroll === b.scroll
        #endif
        return same
    }

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("lane")
        #endif
        let all = Self.segments(
            channel: channel, programs: listings.programs,
            windowStart: windowStart, windowEnd: windowEnd, now: now)
        let previous = Self.previousInRun(all)
        let badge = channel.guideChannelBadge
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: GuideMetrics.rowPitch)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }

            ForEach(all.filter { $0.x < span.upperBound && $0.x + $0.width > span.lowerBound }) { segment in
                switch segment.content {
                case .program(let program):
                    cell(id: segment.id, x: segment.x, action: { onSelect(program) }) {
                        edge(segment, previous: nil) { left in
                            GuideProgramCell(
                                program: program,
                                isAiring: segment.isAiring,
                                width: segment.width,
                                channelBadge: badge,
                                pinnedInset: Self.pinnedInset(segment, left: left))
                        }
                    }
                case .vacancy(let state):
                    cell(id: segment.id, x: segment.x, action: { if state.isTunable { onSelect(nil) } }) {
                        edge(segment, previous: previous[segment.id]) { left in
                            GuideVacancyCell(
                                vacancy: state,
                                isAiring: segment.isAiring,
                                width: segment.width,
                                channelBadge: badge,
                                pinnedInset: Self.pinnedInset(segment, left: left),
                                showsCaption: Self.showsCaption(
                                    segment, previous: previous[segment.id], left: left))
                        }
                    }
                }
            }

            GuideNowMarker(windowStart: windowStart, now: now, width: width, height: GuideMetrics.rowPitch)
        }
        .frame(width: width, height: GuideMetrics.rowPitch, alignment: .topLeading)
    }

    /// One cell placed on the time scale.
    ///
    /// A tap target on the desktop; on tvOS a button, because only a button is
    /// something the remote can land on. Every cell is focusable there, the
    /// untunable ones included: left/right walks a channel's day in order, and
    /// an off-air block that focus skipped would read as a hole the remote
    /// fell through rather than a programme it could not tune. Selecting one
    /// of those simply does nothing, the same as its tap on the desktop.
    @ViewBuilder
    private func cell<Content: View>(
        id: String, x: CGFloat, action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(tvOS)
        let button = Button(action: action) { content() }
            .guideButtonStyle()
            .offset(x: x)
        if let focusedCell {
            button.focused(focusedCell, equals: id)
                .onMoveCommand { direction in onMove?(direction, id) }
        } else {
            button
        }
        #else
        content()
            .offset(x: x)
            .onTapGesture(perform: action)
        #endif
    }

    /// A cell's face, given the lane's visible left edge.
    ///
    /// Off the TV nothing is pinned and the edge is irrelevant. On it, a cell
    /// that cannot straddle the edge anywhere in the current column draws the
    /// same face throughout, so it is drawn once from the column's start; the
    /// one or two that can are drawn from the live edge, and are the only
    /// views a sideways scroll rebuilds between columns.
    @ViewBuilder
    private func edge<Content: View>(
        _ segment: Segment, previous: Segment?,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        #if os(tvOS)
        let start = CGFloat(column) * GuideMetrics.columnWidth
        let end = start + GuideMetrics.columnWidth
        let straddles = { (s: Segment) in s.x < end + 1 && s.x + s.width + GuideMetrics.gap > start - 1 }
        if let scroll, straddles(segment) || previous.map(straddles) == true {
            GuideLiveEdge(scroll: scroll, content: content)
        } else {
            content(start)
        }
        #else
        content(0)
        #endif
    }

    /// How much of a cell has scrolled under the frozen columns. Zero off the
    /// TV, where the reference itself lets a title scroll out of view and the
    /// spec's frame is measured with nothing scrolled.
    private static func pinnedInset(_ segment: Segment, left: CGFloat) -> CGFloat {
        #if os(tvOS)
        max(0, left - segment.x)
        #else
        0
        #endif
    }

    /// One caption per run of vacancy tiles, on the tile the viewer is actually
    /// looking at.
    ///
    /// A gap is cut into half-hour tiles on the TV (see `vacancySegments`), and
    /// captioning each of them would print "No live content right now" three
    /// times across every screen of an empty lane. The bearer is the first
    /// tile of the run whose title still fits beside the left edge: the tile
    /// holding the edge, or the next one along when the edge has eaten too
    /// much of it. Fitting only ever runs from some tile to the run's end, so
    /// that tile is the one that fits while the tile before it does not.
    ///
    /// Off the TV a gap is one cell and always carries its caption.
    private static func showsCaption(_ segment: Segment, previous: Segment?, left: CGFloat) -> Bool {
        #if os(tvOS)
        guard GuideCellTitle.fits(width: segment.width, pinnedInset: max(0, left - segment.x))
        else { return false }
        guard let previous else { return true }
        return !GuideCellTitle.fits(width: previous.width, pinnedInset: max(0, left - previous.x))
        #else
        return true
        #endif
    }

    /// Each vacancy tile's predecessor in the same run, by tile id.
    private static func previousInRun(_ segments: [Segment]) -> [String: Segment] {
        #if os(tvOS)
        var out: [String: Segment] = [:]
        for (before, segment) in zip(segments, segments.dropFirst())
        where segment.runId != nil && segment.runId == before.runId {
            out[segment.id] = before
        }
        return out
        #else
        return [:]
        #endif
    }

    struct Segment: Identifiable {
        enum Content {
            case program(BaseItem)
            case vacancy(GuideVacancy)
        }
        var id: String
        var x: CGFloat
        var width: CGFloat
        var content: Content
        var isAiring: Bool
        /// Tiles cut from one gap share this; nil on a programme. See
        /// `vacancySegments` and `showsCaption`.
        var runId: String?
    }

    /// Walk the window start to finish, emitting a cell per program and a
    /// filler per gap, so a lane never shows bare background.
    ///
    /// Static so the guide can name a lane's n-th cell without laying the lane
    /// out — the TV's focus-preview flag addresses cells by row and column.
    static func segments(
        channel: BaseItem, programs: [BaseItem],
        windowStart: Date, windowEnd: Date, now: Date
    ) -> [Segment] {
        let sorted = programs
            .filter { $0.startDate != nil && $0.endDate != nil }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        func offset(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(windowStart) / 60) * GuideMetrics.widthPerMinute
        }
        func span(_ from: Date, _ to: Date) -> CGFloat {
            GuideMetrics.cellWidth(minutes: to.timeIntervalSince(from) / 60)
        }

        guard !sorted.isEmpty else {
            return vacancySegments(
                idPrefix: "empty-\(channel.id)", from: windowStart, to: windowEnd,
                state: .noRecord, now: now, offset: offset, span: span)
        }

        var out: [Segment] = []
        var cursor = windowStart

        for program in sorted {
            guard let start = program.startDate, let end = program.endDate, end > windowStart
            else { continue }
            if start >= windowEnd { break }

            if start > cursor {
                // A gap: off-air before anything has aired, a hole after.
                let alreadyAired = out.contains { if case .program = $0.content { true } else { false } }
                let state: GuideVacancy = alreadyAired
                    ? .noInformation
                    : .offAir(next: program)
                out.append(contentsOf: vacancySegments(
                    idPrefix: "gap-\(program.id)", from: cursor, to: start,
                    state: state, now: now, offset: offset, span: span))
            }

            let from = max(start, windowStart)
            let to = min(end, windowEnd)
            out.append(Segment(
                id: program.id, x: offset(from), width: span(from, to),
                content: .program(program), isAiring: airing(start, end, now)))
            cursor = max(cursor, to)
        }

        if cursor < windowEnd {
            out.append(contentsOf: vacancySegments(
                idPrefix: "tail-\(channel.id)", from: cursor, to: windowEnd,
                state: .noInformation, now: now, offset: offset, span: span))
        }
        return out
    }

    /// A gap in a lane, as cells: one whole cell off the TV, half-hour tiles on
    /// it.
    ///
    /// Emitted whole, a gap is a single focus target as wide as the gap — a
    /// channel with no listings at all became one button sixteen hours across,
    /// nine screens wide. The focus engine then had one target for the entire
    /// lane: left and right had nowhere to go inside it, and a step out of it
    /// projected that whole-lane frame into the neighbouring row, so moving off
    /// an empty channel landed hours from where the viewer was reading, with no
    /// way back but pressing left through the rest of the day. Cut to the same
    /// 30-minute pitch the ruler is marked in, an empty lane walks exactly like
    /// a programmed one, and only the tile that brackets now lights up instead
    /// of the whole row.
    ///
    /// Off the TV nothing here is focusable and the spec's frame is measured
    /// with the gap whole, so it stays whole.
    static func vacancySegments(
        idPrefix: String, from: Date, to: Date, state: GuideVacancy, now: Date,
        offset: (Date) -> CGFloat, span: (Date, Date) -> CGFloat
    ) -> [Segment] {
        guard to > from else { return [] }
        #if os(tvOS)
        let step: TimeInterval = 30 * 60
        var out: [Segment] = []
        var cursor = from
        var index = 0
        while cursor < to {
            // Tiles break on the half hour, not every half hour from the gap's
            // start, so they line up with the ruler and with the programmes in
            // the lanes above and below.
            let nextTick = Date(timeIntervalSinceReferenceDate:
                (cursor.timeIntervalSinceReferenceDate / step).rounded(.down) * step + step)
            let end = min(max(nextTick, cursor.addingTimeInterval(60)), to)
            out.append(Segment(
                id: "\(idPrefix)-\(index)", x: offset(cursor), width: span(cursor, end),
                content: .vacancy(state), isAiring: airing(cursor, end, now),
                runId: idPrefix))
            cursor = end
            index += 1
        }
        return out
        #else
        return [Segment(
            id: idPrefix, x: offset(from), width: span(from, to),
            content: .vacancy(state), isAiring: airing(from, to, now),
            runId: idPrefix)]
        #endif
    }

    /// Lit-cell test, applied to empty states as well as programs: the band
    /// through the now-marker is the live tell, and a gap must not break it.
    private static func airing(_ from: Date, _ to: Date, _ now: Date) -> Bool {
        from <= now && now < to
    }
}

#if os(tvOS)
extension GuideProgramRow {
    func moveCommands(_ action: @escaping (MoveCommandDirection, String) -> Void) -> GuideProgramRow {
        var row = self
        row.onMove = action
        return row
    }

    /// The guide's focus binding, threaded into a row after construction so the
    /// row's initialiser stays platform-neutral at every call site.
    func focusScope(cellFocus: FocusState<String?>.Binding) -> GuideProgramRow {
        var row = self
        row.focusedCell = cellFocus
        return row
    }

    /// Tell the lane where the viewport's left edge is, so in-progress cells
    /// keep their titles on screen as they scroll under the frozen columns.
    func pinned(to scroll: GuideScrollState, column: Int) -> GuideProgramRow {
        var row = self
        row.scroll = scroll
        row.column = column
        return row
    }
}
#endif

/// Hands a lane the stretch of grid to build, from the grid's column.
///
/// A wrapper of its own so that crossing a half-hour rebuilds the visible
/// lanes and not the guide around them. The span runs a screen either side of
/// the viewport: wide enough that the remote's neighbouring cell always exists
/// to take focus, and that a drag never outruns it between columns.
struct GuideLaneSpan<Content: View>: View {
    let scroll: GuideScrollState
    @ViewBuilder let content: (_ span: Range<CGFloat>, _ column: Int) -> Content

    var body: some View {
        let column = scroll.column
        let visible = scroll.laneViewport.width
        let screen = visible > 0 ? visible : 2400
        let start = CGFloat(column) * GuideMetrics.columnWidth
        content((start - screen)..<(start + GuideMetrics.columnWidth + 2 * screen), column)
    }
}

/// The now-marker's stretch through one row.
///
/// Drawn per row rather than as one line over the grid: off the TV the frozen
/// columns and the ruler scroll with the grid and are pinned over it, and a
/// single overlay drew on top of them. The marker spans the channel rows, not
/// the whole stack — the rows from the first channel down draw it, group
/// headers above that do not — so it begins exactly at the first cell's top
/// edge as the reference's does.
struct GuideNowMarker: View {
    let windowStart: Date
    let now: Date
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let x = CGFloat(now.timeIntervalSince(windowStart) / 60) * GuideMetrics.widthPerMinute
        Rectangle()
            .fill(GuidePalette.nowMarker)
            .frame(width: GuideMetrics.nowMarkerWidth, height: height)
            .offset(x: min(max(x, 0), width))
            .allowsHitTesting(false)
    }
}

/// A channel row's frozen pair: the logo, and the card for what is on now.
///
/// Equatable for the same reason as the lane, and subscribed to its own
/// channel's listings for the card.
struct GuideFrozenCells: View, Equatable {
    let channel: BaseItem
    let listings: GuideListings
    let isPlaying: Bool
    let now: Date
    /// Tune the channel.
    let onSelect: () -> Void
    #if os(tvOS)
    var focus: FocusState<String?>.Binding?
    /// A remote move off the logo (`true`) or the card (`false`).
    var onMove: ((MoveCommandDirection, Bool) -> Void)?
    #endif

    static func == (a: GuideFrozenCells, b: GuideFrozenCells) -> Bool {
        a.listings === b.listings && a.channel == b.channel
            && a.isPlaying == b.isPlaying && a.now == b.now
    }

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("frozen")
        #endif
        let program = listings.airing(on: channel, at: now)
        let vacancy = GuideVacancy.state(of: listings.programs, at: now)
        HStack(spacing: GuideMetrics.gap) {
            Button(action: onSelect) {
                GuideChannelCell(channel: channel, isPlaying: isPlaying)
            }
            .guideButtonStyle()
            #if os(tvOS)
            .modifier(GuideFocusTag(binding: focus, id: "logo:\(channel.id)"))
            .onMoveCommand { direction in onMove?(direction, true) }
            #endif

            // The Now Playing card tunes the channel, except where the
            // reference says there is nothing to tune to.
            Button {
                if program != nil || vacancy.isTunable { onSelect() }
            } label: {
                GuideNowPlayingCell(channel: channel, program: program, vacancy: vacancy)
            }
            .guideButtonStyle()
            #if os(tvOS)
            .modifier(GuideFocusTag(binding: focus, id: "now:\(channel.id)"))
            .onMoveCommand { direction in onMove?(direction, false) }
            #endif
        }
        .frame(height: GuideMetrics.rowPitch, alignment: .top)
    }
}

/// A lineup group's header in the frozen columns. Pressing it collapses or
/// expands the group.
struct GuideGroupHeaderCell: View {
    let group: String
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                Text(group)
                    .font(.system(size: GuideMetrics.smallType(13), weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: GuideMetrics.smallType(11)))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .guideButtonStyle(cornerRadius: 6)
    }
}

#if os(tvOS)
/// `.focused(_:equals:)` when there is a binding to focus through.
struct GuideFocusTag: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}
#endif

extension GuideVacancy {
    /// Which empty state a channel is in at `date`. Off-air and a listings hole
    /// look the same on the surface and are not the same thing.
    static func state(of programs: [BaseItem], at date: Date) -> GuideVacancy {
        let programs = programs
            .filter { $0.startDate != nil }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        guard !programs.isEmpty else { return .noRecord }
        if let next = programs.first(where: { ($0.startDate ?? .distantPast) > date }) {
            let hasEarlier = programs.contains { ($0.endDate ?? .distantPast) <= date }
            return hasEarlier ? .noInformation : .offAir(next: next)
        }
        return .noInformation
    }
}
