import AppIntents
import Foundation

/// One entity for everything Vlinder can start: a library item or a live
/// channel. Keeping them in a single type is what lets a single "Play … on
/// Vlinder" phrase reach both, instead of two phrases that collide in Siri.
struct MediaEntity: AppEntity, Identifiable {
    /// The deep link, verbatim — so an entity that survives in a saved shortcut
    /// still routes through exactly the path a Top Shelf tile uses.
    var id: String
    var title: String
    var subtitle: String?
    var isChannel: Bool

    init(match: MediaResolver.Match) {
        self.id = match.link.url.absoluteString
        self.title = match.title
        self.isChannel = { if case .channel = match { return true }; return false }()
        switch match {
        case .item(let item):
            self.subtitle = item.posterSubtitle
        case .channel(let channel):
            let number = channel.channelNumber ?? channel.number
            self.subtitle = [number, channel.currentProgram?.value.name]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    var link: DeepLink? { URL(string: id).flatMap(DeepLink.init(url:)) }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Media" }

    /// The subtitle is what makes disambiguation answerable: two rows both
    /// reading "The Office" tell the user nothing; "Series" vs "Channel 704"
    /// does.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }

    static var defaultQuery = MediaQuery()
}

/// Looks an entity up by spoken name. App Intents calls this before `perform`,
/// and presents its own picker when it comes back with more than one — which is
/// exactly the honest behaviour for an ambiguous phrase.
struct MediaQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [MediaEntity] {
        guard let client = await SharedSession.clientPreferringLocal() else { return [] }
        return await MediaResolver(client: client)
            .resolve(spoken: string)
            .bestTier
            .map { MediaEntity(match: $0.match) }
    }

    /// Identifiers are self-describing deep links, so a saved shortcut resolves
    /// with one lookup and no search.
    func entities(for identifiers: [MediaEntity.ID]) async throws -> [MediaEntity] {
        guard let client = await SharedSession.clientPreferringLocal() else { return [] }
        var found: [MediaEntity] = []
        for identifier in identifiers {
            guard let url = URL(string: identifier), let link = DeepLink(url: url) else { continue }
            switch link {
            case .play(let itemId):
                if let item = try? await client.item(id: itemId) {
                    found.append(MediaEntity(match: .item(item)))
                }
            case .tune(let channelId):
                if let channel = try? await client.item(id: channelId) {
                    found.append(MediaEntity(match: .channel(channel)))
                }
            }
        }
        return found
    }
}

/// Same shape as `MediaEntity`, but its query only ever offers things the
/// server says are in progress or up next — so "resume" can never quietly start
/// something from scratch.
struct ResumeEntity: AppEntity, Identifiable {
    var id: String
    var title: String
    var subtitle: String?

    init(id: String, title: String, subtitle: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    init(match: MediaResolver.Match) {
        let media = MediaEntity(match: match)
        self.init(id: media.id, title: media.title, subtitle: media.subtitle)
    }

    var link: DeepLink? { URL(string: id).flatMap(DeepLink.init(url:)) }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Show" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }

    static var defaultQuery = ResumeQuery()
}

struct ResumeQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ResumeEntity] {
        guard let client = await SharedSession.clientPreferringLocal() else { return [] }
        return await MediaResolver(client: client)
            .resolveResume(spoken: string)
            .bestTier
            .map { ResumeEntity(match: $0.match) }
    }

    func entities(for identifiers: [ResumeEntity.ID]) async throws -> [ResumeEntity] {
        try await MediaQuery().entities(for: identifiers).map {
            ResumeEntity(id: $0.id, title: $0.title, subtitle: $0.subtitle)
        }
    }

    /// Shown when Siri asks "what would you like to resume?" with nothing said.
    func suggestedEntities() async throws -> [ResumeEntity] {
        guard let client = await SharedSession.clientPreferringLocal() else { return [] }
        return await MediaResolver(client: client)
            .resolveResume(spoken: "")
            .prefix(10)
            .map { ResumeEntity(match: $0.match) }
    }
}

// MARK: - Intents

/// Hands a resolved link to the same router the URL scheme feeds. Every route
/// into playback — Top Shelf tile, Siri phrase, `simctl openurl` — ends here.
@MainActor
private func startPlayback(_ link: DeepLink) {
    DeepLinkRouter.shared.submit(link)
}

struct PlayOnVlinderIntent: AppIntent {
    static var title: LocalizedStringResource = "Play on Vlinder"
    static var description = IntentDescription("Play a movie, show, or live channel from your Jellyfin server.")
    static var openAppWhenRun = true

    /// Optional on purpose: a phrase that matches nothing leaves this nil, and a
    /// spoken "I couldn't find it" is a better answer than the system's silence.
    @Parameter(title: "Title")
    var media: MediaEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$media) on Vlinder")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await SharedSession.load() != nil else {
            return .result(dialog: "Sign in to your Jellyfin server in Vlinder first.")
        }
        guard let media, let link = media.link else {
            return .result(dialog: "I couldn't find that on Vlinder.")
        }
        startPlayback(link)
        return .result(dialog: media.isChannel
            ? "Tuning to \(media.title)."
            : "Playing \(media.title).")
    }
}

struct ResumeOnVlinderIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume on Vlinder"
    static var description = IntentDescription("Pick up a show or movie where you left off.")
    static var openAppWhenRun = true

    @Parameter(title: "Show")
    var show: ResumeEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$show) on Vlinder")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await SharedSession.load() != nil else {
            return .result(dialog: "Sign in to your Jellyfin server in Vlinder first.")
        }
        guard let show, let link = show.link else {
            return .result(dialog: "You don't have that in progress on Vlinder.")
        }
        startPlayback(link)
        return .result(dialog: "Resuming \(show.title).")
    }
}

struct PlaySomethingOnVlinderIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Something on Vlinder"
    static var description = IntentDescription("Continue whatever you were watching, or start the next episode.")
    static var openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Play something on Vlinder")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = await SharedSession.clientPreferringLocal() else {
            return .result(dialog: "Sign in to your Jellyfin server in Vlinder first.")
        }
        guard let match = await MediaResolver(client: client).resolveSomething() else {
            return .result(dialog: "You have nothing waiting on Vlinder right now.")
        }
        startPlayback(match.link)
        return .result(dialog: "Playing \(match.title).")
    }
}

// MARK: - Shortcut phrases

/// The phrases, verbatim. `\(.applicationName)` is "Vlinder" (and any app-name
/// synonyms tvOS has learned), so what the owner actually says is:
///
///   "Hey Siri, play The Bear on Vlinder"
///   "Hey Siri, watch The Bear on Vlinder"
///   "Hey Siri, Vlinder, play The Bear"
///   "Hey Siri, play ESPN on Vlinder"          (channel name, call sign, or number)
///   "Hey Siri, resume Severance on Vlinder"
///   "Hey Siri, continue Severance on Vlinder"
///   "Hey Siri, play something on Vlinder"
///
/// Siri's own media grammar ("play The Bear", with Vlinder chosen as the media
/// app) arrives instead as `INPlayMediaIntent` and is handled by the
/// `VlinderIntents` extension — same resolver, same links.
///
/// None of this can be exercised on the simulator: it has no Siri. Proving it
/// on hardware is one step the owner has to take — install the VlinderTV scheme
/// onto the paired Apple TV from Xcode (Product ▸ Destination ▸ the Apple TV,
/// then Run), and the phrases register on first launch.
struct VlinderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayOnVlinderIntent(),
            phrases: [
                "Play \(\.$media) on \(.applicationName)",
                "Watch \(\.$media) on \(.applicationName)",
                "\(.applicationName), play \(\.$media)",
            ],
            shortTitle: "Play",
            systemImageName: "play.tv")
        AppShortcut(
            intent: ResumeOnVlinderIntent(),
            phrases: [
                "Resume \(\.$show) on \(.applicationName)",
                "Continue \(\.$show) on \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "arrow.clockwise")
        AppShortcut(
            intent: PlaySomethingOnVlinderIntent(),
            phrases: [
                "Play something on \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play something",
            systemImageName: "shuffle")
    }
}

extension Array where Element == MediaResolver.Ranked {
    /// Only the matches that scored as well as the best one. A weaker match is
    /// not a candidate — offering it would turn a clear answer into a needless
    /// question.
    var bestTier: [MediaResolver.Ranked] {
        guard let best = first else { return [] }
        return Array(filter { $0.score == best.score }.prefix(6))
    }
}
