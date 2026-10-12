import SwiftUI

/// One program in the time grid.
///
/// Title top-left, a badge bottom-left, and a lighter background when the
/// program is the one airing now — that background is the reference's only tell
/// for "this is live", so it carries real weight.
struct GuideProgramCell: View {
    let program: BaseItem
    let isAiring: Bool
    let width: CGFloat
    /// A badge the channel earns rather than the program — "4K" and friends are
    /// a property of the feed, and no EPG field reports them.
    var channelBadge: String?
    /// How much of the cell's left has scrolled under the frozen columns. The
    /// title and badge shift right by this much so they stay on the visible
    /// edge: without it an in-progress programme is an anonymous box with a
    /// fragment of a word — "0PM" — at its far left. Zero on the desktop.
    var pinnedInset: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: GuideMetrics.cellCornerRadius, style: .continuous)
            .fill(isAiring ? GuidePalette.cellAiring : GuidePalette.cell)
            .overlay(alignment: .topLeading) {
                if GuideCellTitle.fits(width: width, pinnedInset: pinnedInset) {
                    GuideCellTitle(
                        text: program.name ?? "", lines: titleLines, pinnedInset: pinnedInset)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge, GuideCellTitle.fits(width: width, pinnedInset: pinnedInset) {
                    GuideBadge(text: badge)
                        .padding(.leading, GuideMetrics.badgeLeftInset + pinnedInset)
                        .padding(.bottom, GuideMetrics.badgeBottomInset)
                }
            }
            .frame(width: width, height: GuideMetrics.rowCellHeight)
            .contentShape(Rectangle())
    }

    /// A cell narrow enough that two lines would each hold a syllable reads
    /// worse wrapped than truncated. No cell in the reference frame wraps.
    private var titleLines: Int {
        width - pinnedInset - GuideMetrics.titleInset * 2 < GuideMetrics.scaled(110) ? 1 : 2
    }

    /// One badge, most specific first — the reference never stacks them.
    ///
    /// "New" is the absence of a repeat marker, not the presence of a new one:
    /// this server's XMLTV sets <previously-shown> on 85% of programs and
    /// `<new/>` on none, so keying off `isNew` leaves the badge permanently
    /// dark. Anything with no listing at all stays unbadged rather than being
    /// promoted to new by default.
    private var badge: String? {
        if program.isLive == true { return "Live" }
        if program.isPremiere == true { return "Premiere" }
        if isFirstRun { return "New" }
        return channelBadge
    }

    private var isFirstRun: Bool {
        guard program.isRepeat != true else { return false }
        // A bare title with no series or category behind it is usually filler,
        // and badging filler as new is worse than not badging it.
        return program.isSeries == true || program.episodeTitle != nil
    }
}

/// A cell's headline. Shared so the empty states are typeset as titles rather
/// than as their own near-miss of one.
struct GuideCellTitle: View {
    let text: String
    /// Of the three empty states only the mid-lane listings hole drops out of
    /// title styling; see GUIDE_SPEC's "three empty states".
    var dimmed = false
    var lines = 2
    /// See `GuideProgramCell.pinnedInset`. Added to the leading inset only.
    var pinnedInset: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: GuideMetrics.scaled(19), weight: .regular))
            .foregroundStyle(dimmed ? Color.white.opacity(0.55) : .white)
            .lineLimit(lines)
            .padding(.leading, GuideMetrics.titleInset + pinnedInset)
            .padding(.trailing, GuideMetrics.titleInset)
            .padding(.top, GuideMetrics.titleInset - GuideMetrics.scaled(Self.capSlack))
    }

    /// The leading-edge fit test, the twin of the ruler's trailing one: once
    /// less than a short word's width of the cell is still on screen, the
    /// title comes off rather than being sliced or crushed into the sliver.
    /// Always true off the TV, where nothing is pinned.
    static func fits(width: CGFloat, pinnedInset: CGFloat) -> Bool {
        pinnedInset == 0 || width - pinnedInset >= GuideMetrics.titleInset * 2 + GuideMetrics.scaled(56)
    }

    /// The reference's 16 pt top inset is measured to the glyph caps, but
    /// SwiftUI insets the line box, whose top sits this far above them at 19 pt.
    ///
    /// 19/regular, not 20/medium: at 20 the cap ran 15 against the bar's 14,
    /// and medium put 26% more ink on identical strings while they still
    /// measured shorter — the surplus was stroke weight, not size. The
    /// remaining ~5% width deficit is SF Pro being narrower per unit cap
    /// height, which no point size closes.
    private static let capSlack: CGFloat = 3
}

/// A near-black capsule on the cell. Reads as a chip rather than as text.
struct GuideBadge: View {
    let text: String

    var body: some View {
        Text(text)
            // Insets, not a fixed frame: they put "New" at the reference's
            // 38×18 and "4K" at its 30×18 off the same 11 pt line box.
            .font(.system(size: GuideMetrics.smallType(11), weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, GuideMetrics.scaled(7))
            .padding(.vertical, GuideMetrics.scaled(2))
            .background(GuidePalette.badge, in: Capsule())
    }
}

/// A run of dead air in the grid.
///
/// The lit fill is not a program-cell privilege: an empty state that brackets
/// now has to light up too, or the vertical band through the now-marker — the
/// reference's live tell — breaks at whichever row happens to be off-air.
struct GuideVacancyCell: View {
    let vacancy: GuideVacancy
    let isAiring: Bool
    let width: CGFloat
    var channelBadge: String?
    /// See `GuideProgramCell.pinnedInset`.
    var pinnedInset: CGFloat = 0
    /// False on the tiles of a gap that a neighbouring tile is already
    /// captioning; see `GuideProgramRow.captionBearers`. Always true off the
    /// TV, where a gap is one cell.
    var showsCaption = true

    var body: some View {
        RoundedRectangle(cornerRadius: GuideMetrics.cellCornerRadius, style: .continuous)
            .fill(isAiring ? GuidePalette.cellAiring : GuidePalette.cell)
            .overlay(alignment: .topLeading) {
                if showsCaption, GuideCellTitle.fits(width: width, pinnedInset: pinnedInset) {
                    GuideCellTitle(
                        text: vacancy.label, dimmed: isListingsHole, pinnedInset: pinnedInset)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let channelBadge, showsCaption,
                   GuideCellTitle.fits(width: width, pinnedInset: pinnedInset) {
                    GuideBadge(text: channelBadge)
                        .padding(.leading, GuideMetrics.badgeLeftInset + pinnedInset)
                        .padding(.bottom, GuideMetrics.badgeBottomInset)
                }
            }
            .frame(width: width, height: GuideMetrics.rowCellHeight)
            .contentShape(Rectangle())
    }

    /// Off-air and filler both name something; only the hole has nothing to say.
    private var isListingsHole: Bool {
        if case .noInformation = vacancy { return true }
        return false
    }
}

extension BaseItem {
    /// A badge the channel carries rather than the listing. No EPG field
    /// reports picture format, so the only honest source is what the provider
    /// puts in the channel's own name.
    var guideChannelBadge: String? {
        let name = (name ?? "").uppercased()
        for marker in ["4K", "UHD", "HDR"] where name.contains(marker) {
            return marker == "UHD" ? "4K" : marker
        }
        return nil
    }
}
