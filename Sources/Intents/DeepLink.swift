import Foundation

/// The one URL vocabulary shared by the Top Shelf, the Siri intents, and
/// `xcrun simctl openurl`:
///
///   vlinder://play/<itemId>      play (or resume) a library item
///   vlinder://tune/<channelId>   tune a live TV channel
///
/// Everything that wants playback from outside the app produces one of these
/// and hands it to `PlayerCoordinator` through `DeepLinkRouter`; there is no
/// second path into the player.
enum DeepLink: Equatable {
    case play(itemId: String)
    case tune(channelId: String)

    static let scheme = "vlinder"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // vlinder://play/<id> parses as host "play", path "/<id>".
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return nil }
        switch url.host?.lowercased() {
        case "play": self = .play(itemId: id)
        case "tune": self = .tune(channelId: id)
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .play(let id): return URL(string: "\(Self.scheme)://play/\(id)")!
        case .tune(let id): return URL(string: "\(Self.scheme)://tune/\(id)")!
        }
    }
}
