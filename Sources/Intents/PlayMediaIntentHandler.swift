#if os(tvOS)
import Foundation
import Intents

/// SiriKit's media grammar, alongside the App Intents phrases.
///
/// App Intents alone covers "play <title> on Vlinder"; `INPlayMediaIntent` is
/// what makes the *system's* own media phrasing ("play <title>", picked up when
/// Siri routes media to an app) land here too. Both funnel into `MediaResolver`
/// and then into the same `vlinder://` link, so there is exactly one resolution
/// behaviour to reason about.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    /// Carries the resolved deep link back to the app process.
    static let activityType = "dev.jake.vlinder.play"
    static let activityLinkKey = "link"

    func resolveMediaItems(
        for intent: INPlayMediaIntent
    ) async -> [INPlayMediaMediaItemResolutionResult] {
        let spoken = intent.mediaSearch?.mediaName ?? ""
        guard !spoken.isEmpty else {
            // "play something": the continuation, resolved without a name.
            guard let client = await SharedSession.clientPreferringLocal(),
                  let match = await MediaResolver(client: client).resolveSomething()
            else { return [.unsupported()] }
            return [.success(with: Self.mediaItem(for: match))]
        }
        guard let client = await SharedSession.clientPreferringLocal() else {
            return [INPlayMediaMediaItemResolutionResult.unsupported(forReason: .loginRequired)]
        }
        let ranked = await MediaResolver(client: client).resolve(spoken: spoken)
        guard let best = ranked.first else { return [.unsupported()] }
        let tied = ranked.filter { $0.score == best.score }
        if tied.count > 1 {
            return [.disambiguation(with: tied.prefix(6).map { Self.mediaItem(for: $0.match) })]
        }
        return [.success(with: Self.mediaItem(for: best.match))]
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let identifier = intent.mediaItems?.first?.identifier,
              let url = URL(string: identifier),
              let link = DeepLink(url: url)
        else {
            return INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil)
        }
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.userInfo = [Self.activityLinkKey: link.url.absoluteString]
        // Playback needs the app's AVPlayer and its foreground UI; the extension
        // only ever resolves.
        return INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity)
    }

    /// The identifier *is* the deep link, so `handle` needs no second lookup.
    private static func mediaItem(for match: MediaResolver.Match) -> INMediaItem {
        let type: INMediaItemType
        var artist: String?
        switch match {
        case .channel(let channel):
            type = .tvShow
            artist = channel.channelNumber ?? channel.number
        case .item(let item):
            switch item.type {
            case .movie: type = .movie
            case .episode, .series, .season: type = .tvShow
            default: type = .unknown
            }
            artist = item.seriesName
        }
        return INMediaItem(
            identifier: match.link.url.absoluteString,
            title: match.title,
            type: type,
            artwork: nil,
            artist: artist)
    }
}

/// Principal class of the `VlinderIntents` extension.
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        guard intent is INPlayMediaIntent else { return self }
        return PlayMediaIntentHandler()
    }
}
#endif
