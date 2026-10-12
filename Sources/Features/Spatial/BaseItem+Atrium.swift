import Foundation

// How the Atrium reads a Jellyfin item: what a case prints, which artwork it
// wears, and whether opening it stays on the shelf.
extension BaseItem {
    var atriumShape: AtriumCasePrint.Shape {
        switch type {
        case .season: .season
        case .episode: .episode
        default: .standard
        }
    }

    /// True when the item has a primary image of its own, rather than the one
    /// it inherits from the show above it.
    var hasOwnPrimaryImage: Bool { imageTags?["Primary"] != nil }

    var atriumPrint: AtriumCasePrint {
        .make(
            shape: atriumShape,
            name: displayTitle,
            numberLabel: episodeLabel,
            year: yearLabel,
            childCount: childCount,
            hasOwnArtwork: hasOwnPrimaryImage)
    }

    /// The image a case wears on its outer face. An episode wants its own
    /// still, not the show's poster: on a shelf of episodes the poster is the
    /// one thing they all share.
    var atriumArtRef: ImageRef? {
        switch type {
        case .episode:
            if let tag = imageTags?["Primary"] {
                return ImageRef(itemId: id, tag: tag, type: .primary)
            }
            if let tag = imageTags?["Thumb"] {
                return ImageRef(itemId: id, tag: tag, type: .thumb)
            }
            if let parentThumbItemId, let parentThumbImageTag {
                return ImageRef(itemId: parentThumbItemId, tag: parentThumbImageTag, type: .thumb)
            }
            // No still at all: the jacket is printed on plain stock rather than
            // borrowing a portrait poster that says nothing about this episode.
            return nil
        case .season:
            // Season art first, the show's only as a fallback — the opposite of
            // `posterRef`, which deliberately keeps a show's face on its parts.
            if let tag = imageTags?["Primary"] {
                return ImageRef(itemId: id, tag: tag, type: .primary)
            }
            return posterRef
        default:
            return posterRef
        }
    }

    /// Shows and seasons open onto a shelf of their own instead of leaving the
    /// Atrium for a detail screen.
    var atriumOpensAShelf: Bool {
        switch type {
        case .series: true
        case .season: (seriesId ?? parentId) != nil
        default: false
        }
    }
}
