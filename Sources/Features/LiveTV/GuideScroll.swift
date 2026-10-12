import SwiftUI

/// Where the grid is scrolled, kept out of `GuideView`'s own state.
///
/// The offset changes on every frame of a scroll. Held as `@State` on the guide
/// it rebuilt the whole screen per frame — header, frozen column, every visible
/// lane — which measured ~10 ms of main-thread work a frame on the Mac and
/// 23–38 ms in the TV simulator (see `GuideBench`). Here the views that read
/// `offset` are the only views a scroll rebuilds, and they are leaves; the rest
/// of the guide reads the coarse readings below, which change a few times a
/// second at most.
@MainActor
@Observable
final class GuideScrollState {
    /// The grid's content offset. Per frame: read it from actions, or from a
    /// leaf view that genuinely has to move with every point of a scroll.
    private(set) var offset: CGPoint = .zero
    /// The scroll view's own size — frozen columns and pinned header included
    /// where they scroll with it.
    private(set) var viewport: CGSize = .zero
    /// The 30-minute column at the lanes' left edge. Lanes build only the
    /// cells near it, so they rebuild when it changes, not per frame.
    private(set) var column = 0
    /// The whole hour nearest the left edge: the pager's position.
    private(set) var hour = 0
    /// Which row-pitch band is at the top edge: what the visible loader keys on.
    private(set) var rowBand = 0
    /// True while the grid moves under a finger, momentum, or an animation.
    private(set) var isScrolling = false
    /// The latest move asked of the grid; carried out by `GuideAxisScroll`.
    private(set) var request: GuideScrollRequest?

    /// How much of the scroll view the frozen columns and the pinned header
    /// cover where they scroll with it (the Mac and iPad). Zero on the TV,
    /// where they sit outside it.
    @ObservationIgnored let laneInset: CGSize
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var target: (point: CGPoint, until: Date)?

    init(laneInset: CGSize = .zero) {
        self.laneInset = laneInset
    }

    /// The part of the viewport the lanes are visible in.
    var laneViewport: CGSize {
        CGSize(width: max(viewport.width - laneInset.width, 0),
               height: max(viewport.height - laneInset.height, 0))
    }

    /// Fed by the scroll view, per frame. Every coarse reading is assigned only
    /// when it actually changes: an Observable setter notifies on any write.
    func update(offset: CGPoint? = nil, viewport: CGSize? = nil) {
        if let offset, offset != self.offset {
            self.offset = offset
            let column = Int(max(offset.x, 0) / GuideMetrics.columnWidth)
            if column != self.column { self.column = column }
            let hour = Int((offset.x / (60 * GuideMetrics.widthPerMinute)).rounded())
            if hour != self.hour { self.hour = hour }
            let band = Int(max(offset.y, 0) / GuideMetrics.rowPitch)
            if band != rowBand { rowBand = band }
        }
        if let viewport, viewport != self.viewport { self.viewport = viewport }
    }

    func setScrolling(_ scrolling: Bool) {
        if scrolling != isScrolling { isScrolling = scrolling }
    }

    enum Axis { case horizontal, vertical }

    /// Move one axis and hold the other — where it is, or where it is already
    /// headed, so a step sideways during a vertical glide does not cancel the
    /// glide by carrying through the half-way point it had reached.
    func scroll(_ axis: Axis, to value: CGFloat, duration: Double) {
        var point = heading
        switch axis {
        case .horizontal: point.x = value
        case .vertical: point.y = value
        }
        scroll(to: point, duration: duration)
    }

    func scroll(to point: CGPoint, duration: Double) {
        // The same destination asked twice is one move. A reveal and the focus
        // change it causes both asked for it, and the second restarted the
        // animation from rest — a hitch on every step past the edge. A move
        // to where the grid already is, is no move at all: issued during the
        // TV's first layout, when the scroll view briefly carries a safe-area
        // inset, a jump to (0, 0) came out 224 points down once the inset
        // cleared, and the opening focus landed on a row scrolled away.
        let here = heading
        if abs(here.x - point.x) < 0.5, abs(here.y - point.y) < 0.5 { return }
        token &+= 1
        request = GuideScrollRequest(token: token, point: point, duration: duration)
        target = (point, Date().addingTimeInterval(max(duration, 0.05)))
    }

    /// Where the grid is headed: an unfinished move's destination, or here.
    var heading: CGPoint {
        if let target, Date() < target.until { return target.point }
        return offset
    }
}

/// One move of the grid.
///
/// The token is what makes two identical asks two events: pressing the day
/// pill twice must jump to now twice, and an `onChange` keyed on value alone
/// would swallow the second.
struct GuideScrollRequest: Equatable {
    var token: Int
    /// Both axes, always. `ScrollPosition.scrollTo(y:)` does not leave the
    /// other axis alone — it snaps the grid back to the window's start — so the
    /// axis a caller is not moving is carried through by `GuideScrollState`.
    var point: CGPoint
    var duration: Double
}

/// Carries out `GuideScrollRequest`s on 18+, and keeps the row-id jump tvOS 17
/// had.
///
/// `ScrollViewReader.scrollTo` does not move a two-axis grid on tvOS, which
/// left the pager, the day pill's jump to now and the frozen column's reveal
/// as controls that did nothing. `ScrollPosition` moves it, one point at a
/// time. Off the TV the reader still serves 17 and 14; see `GuideView`.
struct GuideAxisScrollGate: ViewModifier {
    let state: GuideScrollState
    #if os(tvOS)
    var rowId: Binding<String?>
    #endif

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content.modifier(GuideAxisScroll(state: state))
        } else {
            #if os(tvOS)
            // No ScrollPosition on 17; leave it the one jump it did have.
            content.scrollPosition(id: rowId, anchor: UnitPoint(x: 0, y: 0.15))
            #else
            content
            #endif
        }
    }
}

/// The `ScrollPosition` lives here rather than in `GuideView`: the type only
/// exists from 18, and SwiftUI writes it back on every scrolled point, which in
/// the guide's own body would rebuild the screen per frame.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
private struct GuideAxisScroll: ViewModifier {
    let state: GuideScrollState
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: state.request) { _, request in
                guard let request else { return }
                let move = { position.scrollTo(point: request.point) }
                if request.duration > 0 {
                    // A spring, not an ease. A request that lands while the
                    // last one is still moving picks up its velocity instead
                    // of starting over from rest, so a held direction on the
                    // remote glides rather than lurching once per press.
                    withAnimation(.smooth(duration: request.duration), move)
                } else {
                    move()
                }
            }
    }
}

/// Feeds the scroll view's geometry and phase into `GuideScrollState`.
/// `onScrollGeometryChange` fires continuously under AppKit and UIKit alike;
/// before 18 the guide falls back to `GuideScrollOffsetKey`.
struct GuideScrollSync: ViewModifier {
    let state: GuideScrollState
    var onScrolling: (Bool) -> Void = { _ in }

    struct Snapshot: Equatable {
        var offset: CGPoint
        var viewport: CGSize
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Snapshot.self) { geometry in
                    Snapshot(
                        offset: CGPoint(
                            x: geometry.contentOffset.x + geometry.contentInsets.leading,
                            y: geometry.contentOffset.y + geometry.contentInsets.top),
                        viewport: geometry.containerSize)
                } action: { _, snapshot in
                    state.update(offset: snapshot.offset, viewport: snapshot.viewport)
                }
                .onScrollPhaseChange { _, phase in
                    let scrolling = phase != .idle
                    state.setScrolling(scrolling)
                    onScrolling(scrolling)
                }
        } else {
            content
        }
    }
}

struct GuideScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// Hands its content the lanes' visible left edge, read per frame.
///
/// The TV pins a title to that edge when its cell has scrolled partly under
/// the frozen columns. Only the cells that can straddle the edge before the
/// lane's next rebuild are built inside one of these; the rest of the lane
/// reads nothing that changes while it scrolls.
struct GuideLiveEdge<Content: View>: View {
    let scroll: GuideScrollState
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(scroll.offset.x)
    }
}

extension View {
    /// Hold a view at the scroll view's leading edge while the content beside
    /// it scrolls sideways — the frozen columns, inside the scroll view.
    ///
    /// Applied at render time from the view's own geometry, so it moves in the
    /// same frame as the content under it. The columns used to sit outside the
    /// scroll view and follow its reported offset, which rebuilt them per frame
    /// and drew them a frame behind the lanes they label.
    func guidePinnedLeading() -> some View {
        visualEffect { content, proxy in
            content.offset(x: -proxy.frame(in: .scrollView).minX)
        }
    }
}
