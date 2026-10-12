import Foundation

/// What one card on the Live TV wall shows: a channel, and the programme it is
/// in the middle of right now.
///
/// The wall is a picture of a moment, not of a schedule — everything here is
/// "what is on at this second", which is why it carries the elapsed fraction
/// rather than a position in a 16-hour window.
struct LiveWallCard: Identifiable, Equatable {
    let channel: BaseItem
    let program: BaseItem?

    let channelNumber: String
    let channelName: String
    /// The programme's name, falling back to the channel's when the guide has
    /// nothing for this hour.
    let title: String
    /// 0…1 through the airing programme, or nil when the times are unknown.
    let progress: Double?
    let startLabel: String?
    let endLabel: String?
    /// Wide still for the card face: the programme's own, then the channel's.
    let artwork: ImageRef?
    /// True when that picture is a channel logo rather than a still of the
    /// programme. A logo has to be shown whole on a ground of its own; only a
    /// still can be cropped to fill the card.
    let artworkIsLogo: Bool
    let isFavorite: Bool

    var id: String { channel.id }

    /// Live TV is always live; the badge is there to say what kind of thing
    /// you are looking at, not to report a state that varies.
    var isLive: Bool { true }

    /// Two cards are the same card when they would print the same. Comparing
    /// what is on the face — rather than the whole `BaseItem` behind it — is
    /// what lets the wall ignore the progress bar creeping forward every second
    /// and only restand itself when the television actually changes.
    static func == (lhs: LiveWallCard, rhs: LiveWallCard) -> Bool {
        lhs.channel.id == rhs.channel.id
            && lhs.program?.id == rhs.program?.id
            && lhs.channelNumber == rhs.channelNumber
            && lhs.channelName == rhs.channelName
            && lhs.title == rhs.title
            && lhs.startLabel == rhs.startLabel
            && lhs.endLabel == rhs.endLabel
            && lhs.artwork?.itemId == rhs.artwork?.itemId
            && lhs.artwork?.tag == rhs.artwork?.tag
            && lhs.artworkIsLogo == rhs.artworkIsLogo
            && lhs.isFavorite == rhs.isFavorite
    }
}

/// One band of the wall: a lineup group and the channels in it.
struct LiveWallBand: Identifiable, Equatable {
    let name: String
    let cards: [LiveWallCard]
    /// Index into the accent palette, so News and Sports light differently.
    let accentIndex: Int

    var id: String { name }

    /// The glyph on the band's plate, guessed from what the group is called.
    var symbolName: String { LiveWallBand.symbol(for: name) }

    /// Lineup groups arrive qualified — "Cable · News", "Local · Broadcast".
    /// The plate leads with the part that tells the bands apart and keeps the
    /// qualifier as a kicker above it, rather than truncating the whole thing.
    var plateTitle: String {
        name.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces) ?? name
    }

    var plateKicker: String? {
        let parts = name.components(separatedBy: "·")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "·").trimmingCharacters(in: .whitespaces)
    }

    static func symbol(for group: String) -> String {
        let name = group.lowercased()
        if name.contains("news") { return "newspaper" }
        if name.contains("sport") { return "soccerball" }
        if name.contains("movie") || name.contains("cinema") || name.contains("film") { return "film" }
        if name.contains("kid") || name.contains("child") || name.contains("family") { return "teddybear" }
        if name.contains("music") { return "music.note" }
        if name.contains("doc") || name.contains("learn") || name.contains("science") { return "globe.americas" }
        if name.contains("local") || name.contains("broadcast") { return "antenna.radiowaves.left.and.right" }
        if name.contains("entertain") || name.contains("general") { return "sparkles.tv" }
        if name.contains("premium") || name.contains("hbo") || name.contains("max") { return "crown" }
        if name.contains("favorite") { return "heart" }
        return "tv"
    }
}

enum LiveWallArrangement {
    static let allChannelsBandName = "All Channels"
    /// A band has to be able to fill its row. A group of two channels leaves
    /// most of a lane empty, which reads as a broken wall rather than as a
    /// short category — those channels go to the catch-all band instead.
    static let minimumBandSize = 6

    /// Folds the guide's grouped rows into bands. The grouping itself is the
    /// guide's — lineup order, "Other Channels" bucket, provider order within a
    /// group — so the wall and the Xfinity-style guide never disagree about
    /// which channel belongs where.
    @MainActor
    static func bands(from guide: GuideModel, now: LiveWallNowModel? = nil) -> [LiveWallBand] {
        let rows = guide.rows(collapsedGroups: [], searchTerm: "", playingChannelId: nil)

        var bands: [(name: String, channels: [BaseItem])] = []
        for row in rows {
            switch row {
            case .header(let group, _, _):
                bands.append((group, []))
            case .channel(let channel):
                if bands.isEmpty {
                    bands.append((allChannelsBandName, []))
                }
                bands[bands.count - 1].channels.append(channel)
            }
        }

        // Everything from a group too small to fill a row joins the catch-all,
        // keeping its own order, rather than costing a lane of its own.
        var kept: [(name: String, channels: [BaseItem])] = []
        var spare: [BaseItem] = []
        for band in bands {
            if band.channels.count >= minimumBandSize && band.name != allChannelsBandName {
                kept.append(band)
            } else {
                spare.append(contentsOf: band.channels)
            }
        }
        if !spare.isEmpty {
            if let index = kept.firstIndex(where: { $0.name == GuideModel.otherGroupName }) {
                kept[index].channels.append(contentsOf: spare)
            } else {
                kept.append((kept.isEmpty ? allChannelsBandName : GuideModel.otherGroupName, spare))
            }
        }

        return kept.enumerated().map { index, band in
            LiveWallBand(
                name: band.name,
                cards: band.channels.map { card(for: $0, guide: guide, now: now) },
                accentIndex: index)
        }
    }

    /// Channel names arrive from the relay lineup carrying a country prefix
    /// ("US: BBC AMERICA HD"). On a card the size of a stamp that prefix is the
    /// first thing read and the least worth reading, so it comes off — the
    /// grouping already says where the channel is from.
    static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if let colon = name.firstIndex(of: ":") {
            let prefix = name[name.startIndex..<colon]
            if prefix.count <= 3, prefix.allSatisfy({ $0.isLetter }) {
                name = String(name[name.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? raw : name
    }

    @MainActor
    static func card(
        for channel: BaseItem, guide: GuideModel, now: LiveWallNowModel? = nil
    ) -> LiveWallCard {
        let program = now?.program(for: channel.id) ?? guide.airingNow(on: channel)
        let channelName = displayName(channel.displayTitle)
        let still = program?.thumbRef

        return LiveWallCard(
            channel: channel,
            program: program,
            channelNumber: channel.displayChannelNumber ?? "",
            channelName: channelName,
            title: program?.name?.isEmpty == false ? (program?.name ?? channelName) : channelName,
            progress: progress(of: program) ?? channel.currentProgramProgress,
            startLabel: program?.startDate.map { GuideTime.label(for: $0, style: .exact) },
            endLabel: program?.endDate.map { GuideTime.label(for: $0, style: .exact) },
            artwork: still ?? channel.thumbRef ?? channel.posterRef,
            artworkIsLogo: still == nil,
            isFavorite: channel.userData?.isFavorite == true)
    }

    /// How far through its airing a programme is, right now.
    static func progress(of program: BaseItem?, now: Date = Date()) -> Double? {
        guard let program,
              let start = program.startDate,
              let end = program.endDate,
              end > start
        else { return nil }
        let fraction = now.timeIntervalSince(start) / end.timeIntervalSince(start)
        return min(max(fraction, 0), 1)
    }
}
