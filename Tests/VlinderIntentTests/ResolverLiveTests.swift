import XCTest

/// Resolution against the owner's real server. Skips (rather than fails) when
/// no signed-in session is on this machine, so CI and a fresh clone stay green.
///
/// Reads the Mac app's own stored session the same way `scripts/tv-shot.sh`
/// seeds the simulator; the token is used and never printed.
final class ResolverLiveTests: XCTestCase {
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

    func testResolvesAFavouriteChannelByName() async throws {
        let client = try liveClient()
        let channels = try await client.liveTvChannels()
        let favourites = channels.filter { $0.userData?.isFavorite == true }
        try XCTSkipIf(favourites.isEmpty, "No favourite live channels on the server.")
        let name = favourites[0].displayTitle

        let ranked = await MediaResolver(client: client).resolve(spoken: name)
        let ids = ranked.map(\.match.id)
        XCTAssertTrue(ids.contains(favourites[0].id),
                      "\"play \(name) on Vlinder\" did not reach the channel")
        if case .tune = ranked.first?.match.link {} else if ranked.first?.match.id != favourites[0].id {
            XCTFail("the channel was not the best match for its own name")
        }
    }

    func testResumePhraseOnlyOffersThingsActuallyInProgress() async throws {
        let client = try liveClient()
        let resolver = MediaResolver(client: client)
        let inProgress = try await client.resumeItems(limit: 40)
        try XCTSkipIf(inProgress.isEmpty, "Nothing in progress on the server.")
        let title = inProgress[0].seriesName ?? inProgress[0].displayTitle

        let ranked = await resolver.resolveResume(spoken: title)
        XCTAssertFalse(ranked.isEmpty, "\"resume \(title) on Vlinder\" found nothing to resume")
        // Every offer must come from the resume/next-up pool, never the library.
        let pool = Set(inProgress.map(\.id))
            .union((try? await client.nextUp(limit: 40))?.map(\.id) ?? [])
        for offer in ranked {
            XCTAssertTrue(pool.contains(offer.match.id))
        }
    }

    func testPlaySomethingAlwaysProducesALink() async throws {
        let client = try liveClient()
        guard let match = await MediaResolver(client: client).resolveSomething() else {
            throw XCTSkip("Nothing to continue on the server.")
        }
        XCTAssertEqual(DeepLink(url: match.link.url), match.link)
    }

    func testAMissIsAMiss() async throws {
        let client = try liveClient()
        let ranked = await MediaResolver(client: client)
            .resolve(spoken: "zzqx nonexistent programme 8127")
        XCTAssertTrue(ranked.isEmpty, "a nonsense phrase must resolve to nothing, not a guess")
    }
}
