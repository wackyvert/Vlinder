import Foundation

/// What one case on the shelf prints: the text running up its spine, and how
/// its jacket is made up.
///
/// A film or a show arrives with a poster built for exactly this — a portrait
/// jacket with the title already on it. A season usually does not: it inherits
/// the show's poster, so a shelf of seasons would be the same picture over and
/// over. An episode has no poster at all, only a wide still. Both of those get
/// something printed on them, the way a season set prints its own discs.
///
/// Pure and dependency-free — no SceneKit, no API types — so the shelf's
/// typography rules are testable on their own.
struct AtriumCasePrint: Equatable {
    /// Which kind of thing is racked here.
    enum Shape: Equatable {
        /// A film, a show — anything with a jacket of its own.
        case standard
        case season
        case episode
    }

    /// How the case's outer face is made up.
    enum Jacket: Equatable {
        /// The artwork alone, cropped to the case face.
        case cover
        /// A wide still above a printed band.
        case still
        /// An inherited poster with a band printed across its foot.
        case bandedPoster
    }

    /// Title running up the spine.
    var spineTitle: String
    /// Small line at the spine's foot.
    var spineFootnote: String?
    /// Small line above the band's title, e.g. "S2 E5".
    var bandKicker: String?
    /// Title set on the printed band. Nil when the jacket carries its own.
    var bandTitle: String?
    var jacket: Jacket

    /// - Parameters:
    ///   - numberLabel: "S2 E5" for an episode, nil for anything else.
    ///   - year: the year line as it already reads elsewhere ("2008–2013").
    ///   - childCount: episodes in a season, when the server counted them.
    ///   - hasOwnArtwork: whether the artwork belongs to this item rather than
    ///     being inherited from the show above it.
    static func make(
        shape: Shape,
        name: String,
        numberLabel: String? = nil,
        year: String? = nil,
        childCount: Int? = nil,
        hasOwnArtwork: Bool = true
    ) -> AtriumCasePrint {
        switch shape {
        case .standard:
            return AtriumCasePrint(
                spineTitle: name,
                spineFootnote: year,
                bandKicker: nil,
                bandTitle: nil,
                jacket: .cover)

        case .season:
            // The foot of the spine answers "how much is in here?" when the
            // season has no year of its own, which many do not.
            let episodes = childCount.flatMap { count -> String? in
                count > 0 ? "\(count) episode\(count == 1 ? "" : "s")" : nil
            }
            return AtriumCasePrint(
                spineTitle: name,
                spineFootnote: year ?? episodes,
                bandKicker: nil,
                // Nothing to print over a poster the season actually owns.
                bandTitle: hasOwnArtwork ? nil : name,
                jacket: hasOwnArtwork ? .cover : .bandedPoster)

        case .episode:
            // The number is what you look for on a shelf of episodes, so it
            // takes the foot of the spine and heads the jacket's band.
            return AtriumCasePrint(
                spineTitle: name,
                spineFootnote: numberLabel,
                bandKicker: numberLabel,
                bandTitle: name,
                jacket: .still)
        }
    }
}
