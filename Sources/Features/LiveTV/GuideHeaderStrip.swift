import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The strip above the grid: a day picker over the logo column, a "Now Playing"
/// label over the thumbnail column, then the time ruler, which scrolls with the
/// grid, and a pager on the right.
///
/// On the TV the strip sits above the grid and its ruler follows the grid's
/// reported offset. Off the TV the ruler is the grid's own pinned header (see
/// `GuideRulerLane`) and moves in the same frame as the lanes; only the pill,
/// the label and the pager are drawn from here.
enum GuideHeader {
    /// One face for every piece of header type, at the reference's cap height
    /// of 12. The reference runs the pill, "Now Playing" and the ruler on a
    /// single cap row, and one shared size is what holds them there: two sizes
    /// centred in the same box come out on different baselines. Kept as a
    /// platform font so the ruler can measure a label before drawing it.
    static let face = PlatformFont.systemFont(
        ofSize: GuideMetrics.headerType(17), weight: .medium)

    /// The pager, measured off the reference: a 32-pt target apiece, 40 between
    /// centres, and 49 of margin to the frame's right edge.
    static let pagerTarget: CGFloat = GuideMetrics.scaled(32)
    static let pagerCentreSpacing: CGFloat = GuideMetrics.scaled(40)
    static let pagerMargin: CGFloat = GuideMetrics.scaled(49)
    /// The back-step's disc, barely lifted off the page. Not `GuidePalette.pill`,
    /// which at this size reads as a second day picker.
    static let pagerDisc = Color(hex: 0x101115)

    /// Everything the pager takes from the strip's trailing end, its margin
    /// included.
    static var pagerWidth: CGFloat {
        pagerTarget + pagerCentreSpacing + pagerMargin
    }
}

/// The TV's header strip.
struct GuideHeaderStrip: View {
    let windowStart: Date
    let windowEnd: Date
    let contentWidth: CGFloat
    /// The grid's scroll, so the ruler stays glued to it and the pager knows
    /// which hour it is on.
    let scroll: GuideScrollState
    let hourCount: Int
    let onPage: (Int) -> Void
    let onJumpToNow: () -> Void
    #if os(tvOS)
    /// The guide's header-focus binding, so `-GuideFocus pill|back|forward`
    /// can land on these controls; nil when the strip is shown on its own.
    var headerFocus: FocusState<GuideHeaderControl?>.Binding?
    #endif

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("header")
        #endif
        HStack(spacing: GuideMetrics.gap) {
            dayPill
            GuideNowPlayingHeading()
            GuideRulerTrack(
                labels: GuideRulerLabel.labels(from: windowStart, to: windowEnd),
                contentWidth: contentWidth,
                scroll: scroll)
            // The Guide/Channels switch used to follow the pager here on the
            // TV, and took 270 points out of the ruler's lane: the 10:00AM
            // tick landed under it and only two of four labels drew. The guide
            // now puts the switch in the tab bar's band (see GuideView), so
            // the ruler runs to the pager on every platform.
            pager
        }
        .frame(height: GuideMetrics.headerStripHeight)
    }

    private var dayPill: some View {
        #if os(tvOS)
        GuideDayPill(windowStart: windowStart, action: onJumpToNow, headerFocus: headerFocus)
        #else
        GuideDayPill(windowStart: windowStart, action: onJumpToNow)
        #endif
    }

    private var pager: some View {
        #if os(tvOS)
        GuidePager(scroll: scroll, hourCount: hourCount, onPage: onPage, headerFocus: headerFocus)
        #else
        GuidePager(scroll: scroll, hourCount: hourCount, onPage: onPage)
        #endif
    }
}

/// The day picker. Pressing it jumps the grid back to now.
struct GuideDayPill: View {
    let windowStart: Date
    let action: () -> Void
    #if os(tvOS)
    var headerFocus: FocusState<GuideHeaderControl?>.Binding?
    #endif

    var body: some View {
        Button(action: action) {
            HStack {
                Text(dayLabel)
                    .font(Font(GuideHeader.face))
                Spacer(minLength: 4)
                // The reference's caret is a drawn chevron, 16 wide and 9 tall
                // on a hairline stroke, so it is sized and weighted apart from
                // the label rather than inheriting the label's weight.
                Image(systemName: "chevron.down")
                    .font(.system(size: GuideMetrics.scaled(21), weight: .thin))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, GuideMetrics.scaled(14))
            .frame(
                width: GuideMetrics.logoColumnWidth,
                height: GuideMetrics.headerStripHeight)
            .background(GuidePalette.pill, in: RoundedRectangle(
                cornerRadius: GuideMetrics.scaled(8), style: .continuous))
        }
        .guideButtonStyle(cornerRadius: GuideMetrics.scaled(8))
        #if os(tvOS)
        .modifier(HeaderFocusModifier(control: .dayPill, binding: headerFocus))
        #endif
    }

    private var dayLabel: String {
        Calendar.current.isDateInToday(windowStart)
            ? "Today"
            : windowStart.formatted(.dateTime.weekday(.abbreviated).month().day())
    }
}

/// "Now Playing", over the thumbnail column.
struct GuideNowPlayingHeading: View {
    var body: some View {
        Text("Now Playing")
            .font(Font(GuideHeader.face))
            .foregroundStyle(.white)
            .frame(width: GuideMetrics.nowPlayingColumnWidth, alignment: .leading)
    }
}

/// Page back sits on a disc, page forward is a bare glyph on the page. The
/// asymmetry is the reference's: only the one control is drawn as a target.
///
/// The reference dims its back-step at the window's start — its left chevron
/// sits at about a quarter white while the right is near-white — so the pager
/// says whether there is anywhere to go. It reads the grid's hour, which
/// changes once per hour scrolled, never its offset.
struct GuidePager: View {
    let scroll: GuideScrollState
    let hourCount: Int
    let onPage: (Int) -> Void
    #if os(tvOS)
    var headerFocus: FocusState<GuideHeaderControl?>.Binding?
    #endif

    var body: some View {
        let hour = scroll.hour
        HStack(spacing: GuideHeader.pagerCentreSpacing - GuideHeader.pagerTarget) {
            pageButton(systemName: "chevron.left", delta: -1, enabled: hour > 0)
                .background(Circle().fill(GuideHeader.pagerDisc))
            pageButton(systemName: "chevron.right", delta: 1, enabled: hour < hourCount - 1)
        }
        .padding(.trailing, GuideHeader.pagerMargin)
    }

    private func pageButton(systemName: String, delta: Int, enabled: Bool) -> some View {
        Button { onPage(delta) } label: {
            Image(systemName: systemName)
                .font(.system(size: GuideMetrics.smallType(13), weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.52))
                .frame(width: GuideHeader.pagerTarget, height: GuideHeader.pagerTarget)
        }
        .guideButtonStyle(cornerRadius: GuideHeader.pagerTarget / 2)
        // Stays focusable when there is nowhere to go: a disabled button drops
        // out of the focus graph on tvOS, and a remote resting on "back" at the
        // window's start would otherwise be thrown to whatever is nearest.
        // The step itself is a no-op past either end.
        #if os(tvOS)
        .modifier(HeaderFocusModifier(
            control: delta < 0 ? .pageBack : .pageForward, binding: headerFocus))
        #else
        .disabled(!enabled)
        #endif
    }
}

/// One half-hour tick's label, measured once per guide window.
struct GuideRulerLabel: Identifiable {
    let id: Date
    let text: String
    /// The tick's position in the grid's content.
    let x: CGFloat
    /// Advance width of the label in the header face. Measured rather than
    /// read back from the rendered `Text`: a geometry reading arrives a frame
    /// late, by which time the label the fit test rejects has already drawn.
    let width: CGFloat

    @MainActor private static var cache: (start: Date, end: Date, labels: [GuideRulerLabel])?

    /// The window's ticks. Formatting and measuring thirty-odd labels used to
    /// happen on every scrolled frame; they only change with the window.
    @MainActor
    static func labels(from windowStart: Date, to windowEnd: Date) -> [GuideRulerLabel] {
        if let cache, cache.start == windowStart, cache.end == windowEnd { return cache.labels }
        var out: [GuideRulerLabel] = []
        var cursor = windowStart
        while cursor < windowEnd {
            let text = GuideTime.label(for: cursor, style: .compact)
            out.append(GuideRulerLabel(
                id: cursor, text: text,
                x: CGFloat(cursor.timeIntervalSince(windowStart) / 60) * GuideMetrics.widthPerMinute,
                width: measure(text)))
            cursor = cursor.addingTimeInterval(30 * 60)
        }
        cache = (windowStart, windowEnd, out)
        return out
    }

    private static func measure(_ text: String) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: GuideHeader.face])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Whether the label lands wholly inside a ruler `rulerWidth` wide and
    /// scrolled by `offset`, keeping a gap in hand at the trailing edge. One
    /// that would run past it is dropped rather than sliced: the reference
    /// stops its ruler well short of the pager instead of crowding it with a
    /// fragment of a time.
    ///
    /// With `leading`, the same test at the leading edge: a label whose tick
    /// has scrolled under the frozen columns is dropped whole, where the TV's
    /// round-1 frame showed ")AM" against the Now Playing column.
    func fits(offset: CGFloat, width rulerWidth: CGFloat, leading: Bool) -> Bool {
        if leading, x - offset < 0 { return false }
        return x - offset + width <= rulerWidth - GuideMetrics.gap
    }
}

/// The TV's ruler: the labels, shifted by the grid's offset. A leaf — it is
/// the one part of the strip that moves with every scrolled point.
private struct GuideRulerTrack: View {
    let labels: [GuideRulerLabel]
    let contentWidth: CGFloat
    let scroll: GuideScrollState

    var body: some View {
        GeometryReader { geometry in
            let offset = scroll.offset.x
            ZStack(alignment: .leading) {
                ForEach(labels.filter { $0.fits(offset: offset, width: geometry.size.width, leading: true) }) { label in
                    GuideRulerText(text: label.text)
                        .offset(x: label.x)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
            .offset(x: -offset)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: GuideMetrics.headerStripHeight)
    }
}

/// Off the TV: the ruler as the grid's pinned header, scrolling sideways with
/// the lanes because it is laid out with them.
///
/// The trailing fit test runs at render time against the label's own place in
/// the scroll view, so nothing here is rebuilt while the grid moves. Labels
/// that scroll left go under the frozen corner, as the reference has them.
struct GuideRulerLane: View {
    let labels: [GuideRulerLabel]
    let contentWidth: CGFloat
    /// What the scroll view's trailing end keeps for the pager.
    let trailingReserve: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(labels) { label in
                GuideRulerText(text: label.text)
                    .visualEffect { [trailingReserve] content, proxy in
                        let frame = proxy.frame(in: .scrollView)
                        let limit = (proxy.bounds(of: .scrollView)?.width ?? .infinity) - trailingReserve
                        return content.opacity(frame.maxX <= limit - GuideMetrics.gap ? 1 : 0)
                    }
                    .padding(.leading, label.x)
            }
        }
        .frame(width: contentWidth, height: GuideMetrics.headerStripHeight, alignment: .leading)
    }
}

private struct GuideRulerText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(GuideHeader.face))
            .foregroundStyle(.white)
            .fixedSize()
    }
}

#if os(tvOS)
/// The focusable controls in the header strip, for programmatic focus.
enum GuideHeaderControl: Hashable {
    case dayPill, pageBack, pageForward
}

/// `.focused(_:equals:)` when the strip was given a binding, identity when not.
private struct HeaderFocusModifier: ViewModifier {
    let control: GuideHeaderControl
    let binding: FocusState<GuideHeaderControl?>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: control)
        } else {
            content
        }
    }
}

extension GuideHeaderStrip {
    /// Thread the guide's header focus into the strip after construction, so
    /// the call site stays platform-neutral.
    func headerFocusScope(_ binding: FocusState<GuideHeaderControl?>.Binding) -> GuideHeaderStrip {
        var strip = self
        strip.headerFocus = binding
        return strip
    }
}
#endif
