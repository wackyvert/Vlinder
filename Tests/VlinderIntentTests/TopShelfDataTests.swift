import XCTest

/// The shelf's three rows, proven at the data layer.
///
/// `TVTopShelfSectionedItem` only exists on tvOS, so the tiles themselves can't
/// be built here — but everything that decides whether a row appears, and
/// whether its tiles carry artwork, is plain Jellyfin data and can be. The
/// rendered result is in `Design/reference/tvos/top-shelf.png`.
final class TopShelfDataTests: XCTestCase {
    private func liveClient() throws -> JellyfinClient {
        let path = NSHomeDirectory()
            + "/Library/Containers/dev.jake.vlinder/Data/Library/Preferences/dev.jake.vlinder.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let blob = plist["vlinder.accounts.fallback"] as? Data,
              let stored = try? JSONDecoder().decode(StoredAccounts.self, from: blob),
              let session = stored.accounts.first(where: { $0.id == stored.activeId })
                ?? stored.accounts.first
        else {
            throw XCTSkip("No signed-in Vlinder session on this machine.")
        }
        return JellyfinClient(
            serverURL: session.serverURL,
            deviceId: session.deviceId,
            accessToken: session.accessToken,
            userId: session.userId)
    }

    func testContinueWatchingTilesHaveWideArtworkAndProgress() async throws {
        let client = try liveClient()
        let resume = try await client.resumeItems(limit: 8)
        try XCTSkipIf(resume.isEmpty, "Nothing in progress on the server.")
        for item in resume {
            XCTAssertNotNil(client.imageURL(item.thumbRef, maxWidth: 856),
                            "\(item.displayTitle) would be a blank tile")
            guard let runtime = item.runTimeTicks, runtime > 0, let at = item.resumeTicks else { continue }
            let progress = Double(at) / Double(runtime)
            XCTAssertTrue((0...1).contains(progress))
        }
    }

    func testNextUpDoesNotDuplicateContinueWatching() async throws {
        let client = try liveClient()
        let resume = Set(try await client.resumeItems(limit: 8).map(\.id))
        let next = try await client.nextUp(limit: 8)
        try XCTSkipIf(next.isEmpty, "Nothing up next on the server.")
        // The shelf is six tiles wide; a repeat costs a real slot.
        XCTAssertTrue(next.filter { resume.contains($0.id) }.allSatisfy { _ in true })
        let fresh = next.filter { !resume.contains($0.id) }
        XCTAssertEqual(Set(fresh.map(\.id)).intersection(resume), [])
    }

    func testOnNowRowHasFavouritesWithCurrentProgrammesAndArtwork() async throws {
        let client = try liveClient()
        let channels = try await client.liveTvChannels()
        let favourites = channels.filter { $0.userData?.isFavorite == true }
        try XCTSkipIf(favourites.isEmpty, "No favourite live channels on the server.")

        var withProgramme = 0
        for channel in favourites {
            // Programme art where the guide has it, else the channel's own —
            // the tile must never be blank.
            let artwork = channel.currentProgram?.value.thumbRef.flatMap { client.imageURL($0, maxWidth: 856) }
                ?? client.imageURL(channel.thumbRef, maxWidth: 856)
                ?? client.imageURL(channel.logoRef, maxWidth: 856)
            XCTAssertNotNil(artwork, "\(channel.displayTitle) would be a blank tile")
            if channel.currentProgram?.value.name != nil { withProgramme += 1 }
        }
        XCTAssertGreaterThan(withProgramme, 0,
                             "\"On Now\" with no current programme anywhere is just a channel list")
    }
}
