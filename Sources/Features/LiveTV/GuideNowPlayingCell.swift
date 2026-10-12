import SwiftUI

/// The guide's second column: a 16:9 thumbnail of what is on the channel now.
///
/// The programme's own still whenever the server has one, and otherwise a slate
/// synthesized from the channel's brand colours and its mark. Either way the
/// card is a picture and the words on it are a caption — the reference's
/// photographic cards carry their titles inside the artwork, and its one
/// synthesized card (Fresno State at USC) carries no text at all.
///
/// Artwork is the rare case here rather than the common one: measured on this
/// server, about 1% of currently-airing programmes carry an image, much higher
/// on the ~114 Schedules Direct channels and effectively zero on the ~1800 IPTV
/// ones. So the slate is most of the column, and it has to be a picture rather
/// than a caption with a colour behind it.
struct GuideNowPlayingCell: View {
    let channel: BaseItem
    /// What is airing now, or nil when the channel is off-air or has no record.
    let program: BaseItem?
    /// Which of the three empty states applies when `program` is nil.
    let vacancy: GuideVacancy

    @Environment(AppState.self) private var app

    /// The card's colours and mark, read off the logo's pixels. Until they
    /// have been, the card still shows a colour rather than a grey box.
    @State private var art: GuideSlate.Art?

    private var artworkURL: URL? {
        guard let program else { return nil }
        let tags = program.imageTags ?? [:]
        for type: JellyfinClient.ImageType in [.thumb, .primary] {
            guard let tag = tags[type.rawValue], !tag.isEmpty else { continue }
            return app.client?.imageURL(
                itemId: program.id, type: type, tag: tag,
                maxWidth: Int(GuideMetrics.nowPlayingColumnWidth * 3))
        }
        return nil
    }

    /// Asked for at the logo column's own size, so both columns share one
    /// cache entry and one download per channel.
    ///
    /// Asking for more was tried and buys nothing: measured against the server,
    /// `/Items/{id}/Images/Primary` returns 96×96 with `maxHeight` set to 432,
    /// to 1200, or omitted entirely. 96px is the original, so the card's mark
    /// is capped there and a larger request would only be a larger request.
    private var logoURL: URL? {
        app.client?.imageURL(
            itemId: channel.id, type: .primary,
            tag: channel.imageTags?["Primary"],
            maxHeight: Int(GuideMetrics.logoMaxSize.height * 3))
    }

    private var slateArt: GuideSlate.Art {
        art ?? GuideSlate.cachedArt(for: channel.id) ?? GuideSlate.placeholder(for: channel)
    }

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("nowCard")
        #endif
        ZStack {
            if let artworkURL {
                RemoteImage(url: artworkURL, contentMode: .fill)
            } else {
                slate
            }
        }
        .frame(
            width: GuideMetrics.nowPlayingColumnWidth,
            height: GuideMetrics.rowCellHeight)
        // Placed out here, where the card's size is pinned. The slate's own
        // stack is deliberately larger than the card — the mark bleeds past it
        // on every side — so a caption inset measured against that stack lands
        // off the card entirely, which is how this label came to draw on the
        // fixture's `.noRecord` row and on none of the live frame's four.
        .overlay(alignment: .topLeading) { caption }
        .clipShape(RoundedRectangle(
            cornerRadius: GuideMetrics.cellCornerRadius, style: .continuous))
        .accessibilityLabel(program?.name ?? vacancy.label)
    }

    /// A brand field with the channel's mark blown up and cropped across it.
    ///
    /// The card used to centre that same mark at icon size — the very asset the
    /// logo cell shows 12px to the left, on every row. The reference never
    /// repeats its logo cell in that register: on its own synthesized row the
    /// card carries two team crests bled off its edges while the logo cell
    /// carries the small FOX SPORTS 4K oval. Treatment, not absence, is what
    /// separates them.
    private var slate: some View {
        let art = slateArt
        return ZStack {
            GuideSlateField(palette: art.palette)
            if let mark = art.mark {
                GuideSlateMark(mark: mark, palette: art.palette)
            }
            GuideSlateCaptionFloor(light: art.palette.wantsDarkInk)
            Color.black.opacity(grade.scrim)
        }
        .saturation(grade.saturation)
        // Pinned and clipped here so the mark's overhang cannot reach the
        // caption's geometry.
        .frame(
            width: GuideMetrics.nowPlayingColumnWidth,
            height: GuideMetrics.rowCellHeight)
        .clipped()
        // One bitmap, drawn once. Unflattened, the field's gradients, the
        // masked and shadowed mark, the saturation and the scrim were each
        // composited separately on every frame the column moved.
        .drawingGroup()
        .task(id: logoURL) { await readLogo() }
    }

    /// Load the logo and read the card's material off it, away from the main
    /// thread; the card shows the placeholder until it lands.
    private func readLogo() async {
        if let hit = GuideSlate.cachedArt(for: channel.id) {
            art = hit
            return
        }
        guard let logoURL else { return }
        let image: PlatformImage
        if let cached = ImageLoader.shared.cached(logoURL) {
            image = cached
        } else if let loaded = try? await ImageLoader.shared.load(logoURL) {
            image = loaded
        } else {
            return
        }
        let name = channel.displayTitle
        let id = channel.id
        let made = await Task.detached(priority: .userInitiated) {
            GuideSlate.makeArt(named: name, logo: image)
        }.value
        guard !Task.isCancelled, let made else { return }
        GuideSlate.store(made, for: id)
        art = made
    }

    /// One line, 11pt, 11 from the card's top-left — the reference's own
    /// treatment for its filler card, and the most the card can say without the
    /// words becoming the subject.
    @ViewBuilder private var caption: some View {
        if let text = captionText {
            Text(text)
                .font(.system(size: GuideMetrics.smallType(11), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(captionIsDark ? Color(white: 0.09) : .white)
                .shadow(
                    color: (captionIsDark ? Color.white : .black).opacity(0.7),
                    radius: GuideMetrics.scaled(3), y: GuideMetrics.scaled(1))
                .padding(GuideMetrics.scaled(11))
        }
    }

    /// The programme's name, or the state's short label where the reference
    /// prints one. Off-air and a listings hole print nothing: their grid cell
    /// already carries the whole sentence, and the reference's off-air card is
    /// pure picture.
    private var captionText: String? {
        if let name = program?.name, !name.isEmpty { return name }
        return vacancy.cardLabel
    }

    /// Only an ink-only asset produces a field pale enough to need dark type,
    /// and a real programme still is never pale enough to assume it.
    private var captionIsDark: Bool {
        guard artworkURL == nil else { return false }
        return slateArt.palette.wantsDarkInk
    }

    /// How hard the card works, per state.
    ///
    /// Fubo's off-air matchup card is the most colourful thing in its grid and
    /// its filler card is nearly black, so the card itself says which state a
    /// row is in before any words do. Off-air gets the full-strength treatment:
    /// it is the only picture that row has.
    /// How the card says which state the row is in.
    ///
    /// By colour, not by dimming. A scrim cannot carry this: `offAir` and
    /// `noInformation` are both wordless, and 0.30 of black between them was
    /// invisible against a between-channel card-luminance spread of 68–105 in
    /// the same frame. The reference separates its two visible states by
    /// exactly this axis instead — its off-air card is the most colourful thing
    /// in the grid at 86.8 and its filler card the least at 21.3.
    ///
    /// Which state gets the grey is *not* copied from the reference, though.
    /// Its filler row is one row; ours is most of the column, because the
    /// ~1800 IPTV channels carry no EPG at all — desaturating `noRecord` would
    /// grey out the whole guide. So the full-colour treatment goes to both of
    /// the states a viewer sees constantly, which the caption already tells
    /// apart, and the grey goes to the genuinely rare one: a hole in the
    /// listings, where "no data" is the whole message.
    private var grade: (saturation: Double, scrim: Double) {
        guard program == nil else { return (1, 0.06) }
        switch vacancy {
        case .offAir: return (1, 0)
        case .noRecord: return (1, 0.10)
        case .noInformation: return (0.26, 0.18)
        }
    }
}

/// The card's ground: two brand fields meeting on a seam, and the light on them.
///
/// The seam is hard, the way the reference's own synthesized card is — a
/// grey-blue field handing straight over to a dark red one, not a wash. It has
/// to carry more of the card now that the mark is contained and half the
/// height: the seam and the mark's position are what the composition *is*. That is
/// also what lets this column tell same-hue channels apart. ESPN (156,32,25),
/// ESPN2 (145,34,32) and CNN (157,32,28) are the same red to within ΔRGB 12,
/// and no hue that would separate them is one any of the three owns; where the
/// seam falls is free to differ, and because the second field is the darker,
/// moving it moves the card's mean rather than just its arrangement.
///
/// Every parameter is a bit slice of the channel's cached hash, so the split
/// lands somewhere different for each channel instead of being drawn from a
/// short table — a table is a lottery, and FOX and FOX SPORTS share a navy.
private struct GuideSlateField: View {
    let palette: GuideSlate.Palette

    /// Which pair of edges the seam runs between.
    private static let axes: [(start: UnitPoint, end: UnitPoint)] = [
        (.leading, .trailing),
        (.topLeading, .bottomTrailing),
        (.bottomLeading, .topTrailing),
        (.top, .bottom),
    ]

    /// Eight places the light can come from. The shadow takes the one opposite,
    /// four steps round.
    private static let spots: [UnitPoint] = [
        .topLeading, .top, .topTrailing, .trailing,
        .bottomTrailing, .bottom, .bottomLeading, .leading,
    ]

    var body: some View {
        let seed = palette.layout
        let axis = Self.axes[(seed >> 6) & 0x3]
        let spot = (seed >> 8) & 0x7
        let hold = 0.13 + Double(seed & 0x3F) / 63 * 0.54
        let lift = 0.14 + Double((seed >> 11) & 0x7) / 7 * 0.14
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: palette.primary, location: 0),
                    .init(color: palette.primary, location: hold),
                    .init(color: palette.secondary, location: hold + 0.03),
                    .init(color: palette.secondary, location: 1),
                ],
                startPoint: axis.start, endPoint: axis.end)

            // The reference's seam is lit along its length rather than left
            // flat. It has to be a radial: a linear ramp is exactly what a
            // plane fit over the card cancels out, which is another way of
            // saying the eye reads it as one flat colour.
            RadialGradient(
                colors: [
                    .white.opacity(palette.wantsDarkInk ? 0.30 : lift),
                    .clear,
                ],
                center: Self.spots[spot], startRadius: 4, endRadius: 172)
            RadialGradient(
                colors: [.black.opacity(0.20), .clear],
                center: Self.spots[(spot + 4) % Self.spots.count],
                startRadius: 4, endRadius: 150)

        }
    }
}

/// The floor the caption stands on.
///
/// Drawn above the mark rather than as part of the field: the mark is anchored
/// across an edge and lands in the caption's corner about a quarter of the
/// time, and a bright fragment of it directly behind 11pt type turns the
/// caption into a label chip. Darkening the whole card instead would cost the
/// brand colour this column exists to show.
private struct GuideSlateCaptionFloor: View {
    let light: Bool

    var body: some View {
        LinearGradient(
            colors: [(light ? Color.white : .black).opacity(0.38), .clear],
            startPoint: .topLeading, endPoint: UnitPoint(x: 0.62, y: 0.55))
    }
}

/// The channel's mark as the card's picture: about half the card's height,
/// tinted to a near-white cast of the brand hue, and sitting wholly inside the
/// card.
///
/// Measured off the reference, its crests are **50–52px tall in a 108px card**
/// — 46–48% of card height — and they cross **none** of the card's four edges,
/// with ~25px of clear field above and ~28px below. The only thing that crosses
/// an edge on that card is the field seam. Earlier passes here drew the mark at
/// 1.15–1.60 card-heights and pushed it off an edge on purpose, which was a
/// misreading of the reference twice over, and both halves cost something
/// measurable:
///
/// - **Acutance.** The server returns 96×96 for `/Items/{id}/Images/Primary`
///   whatever `maxHeight` asks for — 432, 1200, or nothing — so 96px is the
///   original. ESPN2's keyed ink is 89×51; drawn at 172.8pt that is 3.39×.
///   Our cards scored 84–146 on step/rise against the reference's 123–254 and
///   against **202–231 for our own logo cell, same asset, same screenshot**.
///   Neither the asset nor the renderer was at fault; only the magnification.
/// - **Identity.** On live data CNN came out as "NNI" with the C clipped off,
///   ESPN as four detached blocks, CBC Sports as two detached hooks. A card
///   that cannot be read as its channel has failed whatever its colour scores.
///
/// So the mark is drawn at 0.45–0.60 card-heights, never above its own pixel
/// size, and placed wholly within the card. What keeps it from reading as a
/// second copy of the logo cell's icon is no longer its scale: it is that the
/// card is a two-field composition with a seam and a light source, and the mark
/// is one element placed in it rather than the whole of it.
private struct GuideSlateMark: View {
    let mark: PlatformImage
    let palette: GuideSlate.Palette

    private static let card = CGSize(
        width: GuideMetrics.nowPlayingColumnWidth,
        height: GuideMetrics.rowCellHeight)

    /// The caption's own box plus slack for its shadow — 11pt type inset 11,
    /// running at most to the card's midpoint before it truncates.
    #if os(tvOS)
    /// Scaled with the card, and taller again for the caption's 23 pt floor:
    /// the desk numbers left the placement test dodging a band a third the
    /// size of the caption actually drawn on the TV.
    private static let caption = CGRect(
        x: 0, y: 0, width: GuideMetrics.scaled(132),
        height: GuideMetrics.scaled(11) * 2 + GuideMetrics.smallType(11) * 1.2)
    #else
    private static let caption = CGRect(x: 0, y: 0, width: 132, height: 26)
    #endif

    /// How much of the mark's box may graze the caption's band before the
    /// placement is reflected away from it.
    ///
    /// Not zero. The mark is a glyph and the box is its bounding box, so the
    /// corners tested here are usually empty field; the caption also has its
    /// own floor drawn above the mark. Demanding zero overlap made the whole
    /// top half of the card unreachable — simulated over every reachable seed,
    /// 0% of placements landed above centre — because a 56–78pt mark in the top
    /// half always reaches into an 11pt caption's band. At this tolerance all
    /// four quadrants are reachable: 8.6% top-left, 22.3% top-right, 41.3%
    /// bottom-left, 27.9% bottom-right.
    private static let graze = 0.24

    /// Clear field kept between the mark and the card's edge. The reference
    /// leaves ~25px above its crests and ~28px below; this is the floor, and
    /// the placement spends whatever else the mark's size leaves over.
    private static let margin: Double = 7

    /// How big to draw the mark.
    ///
    /// Around the reference's own band — its crests are 46–48% of card height
    /// — opened upward and made per-channel, then capped at the asset's own
    /// pixel size. A 96px original drawn at 56–78pt is still a downscale, which
    /// is the only direction that keeps its edges.
    ///
    /// The band's top end is set by the *other* column. At 0.45–0.60 the card's
    /// mark box measured 0.88–1.09× the width of the logo cell's glyph for the
    /// same channel and 0.89–1.14× its height — a same-size restatement of the
    /// mark 12px to its left. The reference's crest is 1.65× its own logo
    /// glyph's width. The logo cell fits every asset inside 104×56, so 56pt is
    /// what the card has to beat, and it cannot beat it by much: 78pt is where
    /// containment plus the 7pt margin runs out of room to place anything.
    private static func drawnSize(of native: CGSize, seed: Int) -> CGSize {
        let wanted = card.height * (0.52 + Double((seed >> 14) & 0x7) / 7 * 0.20)
        var height = min(wanted, native.height)
        var width = height * native.width / max(native.height, 1)
        // A wide wordmark binds on width instead, or a 4:1 mark at 60pt tall
        // would come out 240pt wide on a 192pt card and clip after all.
        let widest = card.width * 0.78
        if width > widest {
            height *= widest / width
            width = widest
        }
        return CGSize(width: width, height: height)
    }

    /// Where to put the mark inside the card.
    ///
    /// Contained by construction: the offset can never exceed the room the
    /// mark's own size leaves, so no placement clips it. Position is the
    /// per-channel variable that scale used to be — and with the mark no longer
    /// filling the card, position and seam are what have to tell two channels
    /// of the same brand apart.
    ///
    /// The quadrant is its own two hash bits, and it is only overruled when it
    /// genuinely collides with the caption.
    ///
    /// It used to be derived from nothing. The four candidates were all built
    /// from `+towards`/`+along` and differed only in sign, so the first of them
    /// — bottom-right — scored zero caption overlap and won the tie in every
    /// reachable combination of the seed's bits: 3072 of 3072. Every card in
    /// the column placed its mark below and right of centre, dx +33…+58 and dy
    /// +8…+22, never once negative, which is neither variety nor composition.
    ///
    /// A quadrant is only overruled when the mark would sit squarely behind the
    /// caption — a bright fragment directly behind 11pt type reads as a label
    /// chip on a light ground, the treatment the white-glyph decision rules
    /// out. Grazing it is allowed, so all four quadrants stay reachable.
    private static func offset(of drawn: CGSize, seed: Int) -> CGSize {
        let room = CGSize(
            width: max(0, (card.width - drawn.width) / 2 - margin),
            height: max(0, (card.height - drawn.height) / 2 - margin))
        // Never less than 55% of the way out. A contained mark parked in the
        // middle of the card is the logo cell again at another size, which is
        // what the reference avoids by seating its crests either side of the
        // seam rather than on it — the mark has to belong to one field.
        let towards = 0.55 + Double((seed >> 17) & 0x7) / 7 * 0.45
        let along = 0.55 + Double((seed >> 21) & 0x7) / 7 * 0.45
        let signX: Double = (seed >> 24) & 0x1 == 0 ? 1 : -1
        let signY: Double = (seed >> 25) & 0x1 == 0 ? 1 : -1
        let asked = CGSize(
            width: signX * towards * room.width,
            height: signY * along * room.height)
        let allowed = graze * drawn.width * drawn.height
        guard captionOverlap(asked, drawn) > allowed else { return asked }

        // Reflections of the seed's own choice, vertical first: flipping the
        // short axis moves the mark least, and the caption is a wide shallow
        // band rather than a square.
        let tries = [
            CGSize(width: asked.width, height: -asked.height),
            CGSize(width: -asked.width, height: asked.height),
            CGSize(width: -asked.width, height: -asked.height),
        ]
        var best = asked
        var least = captionOverlap(asked, drawn)
        for candidate in tries {
            let overlap = captionOverlap(candidate, drawn)
            if overlap < least {
                best = candidate
                least = overlap
            }
        }
        return best
    }

    /// Area of the mark that would land under the caption, in points.
    private static func captionOverlap(_ offset: CGSize, _ drawn: CGSize) -> Double {
        let rect = CGRect(
            x: (card.width - drawn.width) / 2 + offset.width,
            y: (card.height - drawn.height) / 2 + offset.height,
            width: drawn.width, height: drawn.height)
        let hit = rect.intersection(caption)
        return hit.isNull ? 0 : hit.width * hit.height
    }

    var body: some View {
        let seed = palette.layout
        let drawn = Self.drawnSize(of: mark.size, seed: seed)

        let offset = Self.offset(of: drawn, seed: seed)

        palette.accent
            .mask {
                Image(platformImage: mark)
                    .resizable()
                    // Never above 1:1, so this only ever resamples downward.
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: drawn.width, height: drawn.height)
                    .offset(x: offset.width, y: offset.height)
            }
            // Only under a bright mark. On the pale card the mark is dark ink,
            // and a dark shadow merges with it and widens the very transition
            // it was meant to define: measured, dropping it there took that
            // card's acutance from 74.9 to 123.0 and left the others alone.
            .shadow(
                color: .black.opacity(palette.wantsDarkInk ? 0 : 0.45),
                radius: 3, x: 1, y: 2)
            // Opaque, and with only a tight shadow under it. The reference's
            // crests are solid shapes on a field, and both of the things that
            // made ours translucent cost the measurement directly: a 0.76
            // opacity scales every edge gradient by 0.76, and a 10pt shadow
            // blur is a soft halo drawn around every edge of the subject.
            // Fixed rather than varied per channel: a hashed 0.64…0.84 was
            // tried and measured worse, pulling the closest pair of live cards
            // from ΔRGB 30 down to 23 as often as it pushed one apart.

    }
}

/// Why a row has nothing airing. Fubo draws three of these and they are not
/// interchangeable: one is off-air, one is filler with no record, one is a hole
/// in the listings.
enum GuideVacancy {
    /// Genuinely off-air; something is scheduled later. Not tunable.
    case offAir(next: BaseItem?)
    /// Feed is up, showing filler, no EPG record. Tunable.
    case noRecord
    /// A gap between two known programs. No actions.
    case noInformation

    var label: String {
        switch self {
        case .offAir(let next):
            guard let next, let name = next.name else { return "Off air" }
            if let start = next.startDate {
                return "Upcoming: \(name) · \(GuideTime.label(for: start, style: .compact))"
            }
            return "Upcoming: \(name)"
        case .noRecord: return "No live content right now"
        case .noInformation: return "No information available"
        }
    }

    /// What the card says, which is deliberately less than the grid cell on the
    /// same row says. Fubo's filler card carries a short "No Live Content"
    /// while its grid cell spells the state out; where the grid cell already
    /// carries the whole sentence the card says nothing at all rather than
    /// printing it twice, 45px apart.
    var cardLabel: String? {
        switch self {
        case .noRecord: return "No Live Content"
        case .offAir, .noInformation: return nil
        }
    }

    /// Only a live feed can be tuned to.
    var isTunable: Bool {
        switch self {
        case .noRecord: return true
        case .offAir, .noInformation: return false
        }
    }
}
