#if os(tvOS)
import Foundation
import TVServices

/// Vlinder's Apple TV home-screen shelf.
///
/// Sectioned rather than carousel: the shelf's job here is the same as the TV
/// app's — three short, named rows the user recognises at a glance (what they
/// were watching, what's next, what's on) — not one rotating hero. Every tile
/// is 16:9 with real server artwork; a tile with no artwork still carries its
/// title, because a blank tile is worse than a plain one.
///
/// The session comes from the App Group mirror. Signed out (or mirror missing)
/// publishes nothing at all: the shelf must never become a sign-in prompt.
final class TopShelfContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        Task {
            completionHandler(await Self.content())
        }
    }

    static func content() async -> TVTopShelfContent? {
        guard let client = await SharedSession.clientPreferringLocal() else { return nil }

        // All three rows in parallel: the shelf is fetched on the system's
        // schedule and a serialised fetch would triple the window in which the
        // home screen shows stale tiles.
        async let resume = client.resumeItems(limit: 8)
        async let next = client.nextUp(limit: 8)
        async let channels = client.liveTvChannels()

        let sections = sections(
            resume: (try? await resume) ?? [],
            nextUp: (try? await next) ?? [],
            channels: (try? await channels) ?? [],
            client: client)
        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }

    static func sections(
        resume: [BaseItem],
        nextUp: [BaseItem],
        channels: [BaseItem],
        client: JellyfinClient
    ) -> [TVTopShelfItemCollection<TVTopShelfSectionedItem>] {
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        if !resume.isEmpty {
            let section = TVTopShelfItemCollection(
                items: resume.map { videoTile(for: $0, client: client) })
            section.title = "Continue Watching"
            sections.append(section)
        }

        // Next Up minus anything already offered above: the shelf is six tiles
        // wide, so a duplicate costs a real slot.
        let resumeIds = Set(resume.map(\.id))
        let freshNextUp = nextUp.filter { !resumeIds.contains($0.id) }
        if !freshNextUp.isEmpty {
            let section = TVTopShelfItemCollection(
                items: freshNextUp.map { videoTile(for: $0, client: client) })
            section.title = "Next Up"
            sections.append(section)
        }

        let favourites = channels
            .filter { $0.userData?.isFavorite == true }
            .sorted { channelOrder($0) < channelOrder($1) }
        if !favourites.isEmpty {
            let section = TVTopShelfItemCollection(
                items: favourites.prefix(12).map { channelTile(for: $0, client: client) })
            section.title = "On Now"
            sections.append(section)
        }

        return sections
    }

    // MARK: - Tiles

    private static func videoTile(for item: BaseItem, client: JellyfinClient) -> TVTopShelfSectionedItem {
        let tile = TVTopShelfSectionedItem(identifier: item.id)
        tile.title = item.displayTitle
        tile.imageShape = .hdtv
        if let url = client.imageURL(item.thumbRef, maxWidth: 856) {
            tile.setImageURL(url, for: .screenScale1x)
            tile.setImageURL(url, for: .screenScale2x)
        }
        // The shelf's own progress bar, so a half-watched episode reads as
        // half-watched without opening the app.
        if let ticks = item.runTimeTicks, ticks > 0, let resume = item.resumeTicks, resume > 0 {
            tile.playbackProgress = min(1, Double(resume) / Double(ticks))
        }
        let action = TVTopShelfAction(url: DeepLink.play(itemId: item.id).url)
        tile.playAction = action
        tile.displayAction = action
        return tile
    }

    private static func channelTile(for channel: BaseItem, client: JellyfinClient) -> TVTopShelfSectionedItem {
        let tile = TVTopShelfSectionedItem(identifier: channel.id)
        let program = channel.currentProgram?.value
        // A sectioned tile has one line of text, and both halves matter: the
        // channel is what the user recognises, the programme is what makes this
        // row "On Now" rather than a channel list.
        tile.title = [channel.displayTitle, program?.name]
            .compactMap { $0 }.joined(separator: " · ")
        tile.imageShape = .hdtv

        // Programme artwork where the guide has it, else the channel's own logo:
        // an EPG without images must still produce a recognisable tile.
        let url = program.flatMap { client.imageURL($0.thumbRef, maxWidth: 856) }
            ?? client.imageURL(channel.thumbRef, maxWidth: 856)
            ?? client.imageURL(channel.logoRef, maxWidth: 856)
        if let url {
            tile.setImageURL(url, for: .screenScale1x)
            tile.setImageURL(url, for: .screenScale2x)
        }
        if let progress = channel.currentProgramProgress {
            tile.playbackProgress = min(1, max(0, progress))
        }
        let action = TVTopShelfAction(url: DeepLink.tune(channelId: channel.id).url)
        tile.playAction = action
        tile.displayAction = action
        return tile
    }

    /// Channel numbers are strings like "704" or "5.1"; sort them the way the
    /// guide does rather than lexically ("10" must not precede "2").
    private static func channelOrder(_ channel: BaseItem) -> Double {
        let raw = channel.channelNumber ?? channel.number ?? ""
        return Double(raw.split(separator: ".").prefix(2).joined(separator: ".")) ?? .greatestFiniteMagnitude
    }
}
#endif
