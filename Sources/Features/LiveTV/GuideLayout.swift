import SwiftUI

/// Guide geometry, measured off `Design/reference/live-tv-guide.png`.
///
/// These are not taste; they are the reference frame's own numbers. Read
/// `Design/reference/GUIDE_SPEC.md` before changing any of them.
enum GuideMetrics {
    /// One multiplier over the whole geometry, and the type set on it.
    ///
    /// The reference was measured on a desk: 19 pt titles, 11 pt badges, seven
    /// rows in 852 points. On a television the same numbers are read from ten
    /// feet — the same guide shot for the TV came back with captions that could
    /// not be read at all — so every measured value below is multiplied by this
    /// once, on tvOS only. 1.4 puts the title at ~27 pt (tvOS body type runs
    /// 25–29), leaves five and a half rows on a 1080-point screen and about an
    /// hour and forty minutes of grid, which is what Fubo's own TV guide shows.
    ///
    /// On macOS and iOS the factor is exactly 1, so every constant is bit-for-bit
    /// the value GUIDE_SPEC.md measured. The spec's numbers are not being
    /// re-derived here; they are the base the TV scales from.
    #if os(tvOS)
    static let scale: CGFloat = 1.4
    #else
    static let scale: CGFloat = 1
    #endif

    /// A desk-measured point size, at the platform's scale. For type and the
    /// few insets that live in the views rather than here.
    static func scaled(_ points: CGFloat) -> CGFloat { points * scale }

    /// A desk-measured size for the guide's *small* type — badges, the card
    /// caption, the group header, the pager glyph — at the platform's scale,
    /// with a floor on the TV.
    ///
    /// The uniform 1.4 puts an 11 pt badge at 15 pt, which on a television is
    /// still the desk-sized caption the round-0 frame was faulted for: tvOS
    /// sets nothing it expects to be read below about 20 pt (its caption2).
    /// Scaling everything harder would push the grid off the screen, so the
    /// small type alone is lifted to that floor. Off the TV this is exactly
    /// `scaled(_:)`, and the measured numbers stand.
    static func smallType(_ points: CGFloat) -> CGFloat {
        #if os(tvOS)
        max(points * scale, smallTypeFloor)
        #else
        points * scale
        #endif
    }

    /// A desk-measured size for the guide's *header* type — the day pill, "Now
    /// Playing", the ruler, the mode switch — at the platform's scale, with a
    /// higher floor on the TV than the small type gets.
    ///
    /// The ruler is the guide's wayfinding, read at a glance from the sofa, and
    /// 17 × 1.4 = 23.8 pt measured a 17 px cap on the round-1 frame: tvOS's
    /// caption size, for the one line of type a viewer reads more often than
    /// any title. Its footnote/body floor is 29, so that is the floor here.
    static func headerType(_ points: CGFloat) -> CGFloat {
        #if os(tvOS)
        max(points * scale, headerTypeFloor)
        #else
        points * scale
        #endif
    }

    #if os(tvOS)
    /// tvOS's smallest legible size is its caption2 at 23 pt; the round-1
    /// floor of 20 rendered the badge at a 14 px cap and the Now Playing
    /// caption at ~20 pt, both below what the platform itself will set.
    static let smallTypeFloor: CGFloat = 23
    /// tvOS's footnote and body run at 29 pt; see `headerType(_:)`.
    static let headerTypeFloor: CGFloat = 29
    #endif

    /// Cell heights and the pitch between rows. The gap is the difference.
    static let rowCellHeight: CGFloat = 108 * scale
    static let rowPitch: CGFloat = 120 * scale
    static let gap: CGFloat = 12 * scale

    /// Row height as the layout consumes it (cell + the gap below it).
    static let rowHeight: CGFloat = rowPitch
    static let groupHeaderHeight: CGFloat = 38 * scale
    static let headerStripHeight: CGFloat = 48 * scale
    /// The time-label row's height. Same strip as the "Today" pill sits in.
    static let timelineHeight: CGFloat = 48 * scale

    /// The three columns, left to right.
    static let logoColumnWidth: CGFloat = 152 * scale
    static let nowPlayingColumnWidth: CGFloat = 192 * scale
    static let contentLeftInset: CGFloat = 79 * scale
    #if os(tvOS)
    /// Background above the header strip, measured from the *screen's* top:
    /// on the TV the guide ignores the safe area and lays itself out against
    /// the screen, because the safe area is where the round-1 frame lost a
    /// row. The system's floating tab bar occupies y 46–113 and the safe area
    /// it hands down starts at 157, so with the reference's 71 (51 × 1.4)
    /// below that the header landed at 228 — 115 px of black between the bar
    /// and the guide, and the fifth channel row sliced by the bottom edge.
    ///
    /// The density decision, with the numbers. A 1080-point screen minus the
    /// tab bar's band leaves 967 for the guide. At 1.4× (pitch 168, cell 150,
    /// header 67 + gap 17 = 84) five rows need 84 + 150 + 4 × 168 = 906;
    /// six need 1074. At 1.25× (pitch 150, cell 135, header 60 + 15) six rows
    /// need 75 + 135 + 5 × 150 = 960 — which fits only with the header
    /// touching the tab bar, and the sixth row's bottom on the screen's last
    /// scanline, inside the overscan the platform tells us not to draw in.
    /// So six rows and the floating tab bar cannot coexist at either scale,
    /// and 1.4× stays: 27 pt titles read from ten feet where 24 pt ones did
    /// not, and the geometry is a clean multiple of the spec's rather than a
    /// third set of numbers. Five clean rows, header top at 140 (27 below the
    /// bar), last cell's bottom at 1046, 34 spare above the overscan.
    static let contentTopInset: CGFloat = 140
    /// Channel rows the grid shows at once; the arithmetic above.
    static let visibleRows: CGFloat = 5
    /// The band the system's floating tab bar sits in, y 46–113: the mode
    /// switch is drawn in that band, right-aligned, out of the ruler's lane.
    /// Its height is the header strip's own (67), so the two read as one
    /// toolbar row.
    static let tabBarBandTop: CGFloat = 46
    /// Clear field kept at the screen's right edge, where a partial cell fades
    /// out rather than hard-clipping. 80 is tvOS's own horizontal overscan
    /// margin.
    static let trailingFade: CGFloat = 80
    #else
    /// Background above the header strip. The reference spends 51 here and 12
    /// below, and the strip reads as starved without both.
    static let contentTopInset: CGFloat = 51 * scale
    #endif

    /// 568 px per hour — the reference's scale (Fubo's own grid measures ~9.45).
    static let widthPerMinute: CGFloat = 568.0 / 60.0 * scale

    /// Half an hour of grid: the ruler's tick, and the step lanes rebuild on.
    static let columnWidth: CGFloat = 30 * widthPerMinute

    /// 8, to render the reference's corner. Measured per top scanline the bar
    /// cuts [4,2,1,1,0…] and SwiftUI rasterises a pixel tighter at the same
    /// nominal radius, so this reads high by design — do not "correct" it to 6.
    static let cellCornerRadius: CGFloat = 8 * scale
    static let nowMarkerWidth: CGFloat = 2 * scale

    /// Largest glyph box a channel logo may occupy inside its cell. Logos are
    /// the biggest thing in the row; this is a ceiling, not a uniform frame.
    static let logoMaxSize = CGSize(width: 104 * scale, height: 56 * scale)

    /// Program title inset from its cell's top-left.
    static let titleInset: CGFloat = 16 * scale
    /// Badge inset from its cell's left, and from the cell's bottom.
    static let badgeLeftInset: CGFloat = 17 * scale
    static let badgeBottomInset: CGFloat = 13 * scale
    /// Favorite star inset from the logo cell's top-left.
    static let starInset: CGFloat = 14 * scale

    /// The focus ring's stroke on tvOS: the one guide mark with no desk
    /// counterpart, so it is set at TV size directly rather than scaled up.
    static let focusRingWidth: CGFloat = 5

    /// Everything left of the scrolling grid.
    static var frozenWidth: CGFloat {
        logoColumnWidth + gap + nowPlayingColumnWidth + gap
    }

    static func leftColumnWidth(compact: Bool) -> CGFloat {
        compact ? logoColumnWidth * 0.8 + gap + nowPlayingColumnWidth * 0.8 + gap : frozenWidth
    }

    /// A program cell's drawn width: its duration on the time scale, less one
    /// gap so neighbours don't touch.
    static func cellWidth(minutes: Double) -> CGFloat {
        max(24 * scale, CGFloat(minutes) * widthPerMinute - gap)
    }
}

/// The reference's palette, sampled from the PNG.
enum GuidePalette {
    static let page = Color(hex: 0x06070A)
    static let cell = Color(hex: 0x161822)
    static let cellAiring = Color(hex: 0x232733)
    static let pill = Color(hex: 0x2D2E34)
    static let badge = Color(hex: 0x050608)
    static let nowMarker = Color(hex: 0xFF3A03)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
