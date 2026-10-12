import XCTest

/// What Siri actually decides, tested without Siri: the ranking that separates
/// "one obvious answer" from "ask the user".
final class MediaResolverTests: XCTestCase {
    func testNormalizationSurvivesHowSiriTranscribes() {
        XCTAssertEqual(MediaResolver.normalize("The Bear"), "bear")
        XCTAssertEqual(MediaResolver.normalize("WALL·E"), "wall e")
        XCTAssertEqual(MediaResolver.normalize("Star Wars: A New Hope"), "star wars a new hope")
        XCTAssertEqual(MediaResolver.normalize("  amélie "), "amelie")
    }

    func testExactBeatsPrefixBeatsSubstring() {
        let needle = MediaResolver.normalize("the bear")
        XCTAssertEqual(MediaResolver.score(needle: needle, candidates: ["The Bear"]), 3)
        XCTAssertEqual(MediaResolver.score(needle: needle, candidates: ["The Bear Returns"]), 2)
        XCTAssertEqual(MediaResolver.score(needle: needle, candidates: ["Watching The Bear Again"]), 1)
        XCTAssertNil(MediaResolver.score(needle: needle, candidates: ["Succession"]))
    }

    func testChannelNumberIsMatchable() {
        // "play 704 on Vlinder" has to reach the channel, not miss.
        let needle = MediaResolver.normalize("704")
        XCTAssertEqual(MediaResolver.score(needle: needle, candidates: ["ESPN", "704"]), 3)
    }

    func testGibberishDoesNotMatchAShortChannelNumber() {
        // Regression: a live run resolved this phrase to a channel numbered "8",
        // because "8" is a substring of "8127". Matching is word-bounded now.
        let needle = MediaResolver.normalize("zzqx nonexistent programme 8127")
        XCTAssertNil(MediaResolver.score(needle: needle, candidates: ["8"]))
        XCTAssertNil(MediaResolver.score(needle: needle, candidates: ["ESPN", "12"]))
    }

    func testMultiWordPhraseStillMatchesWholeWords() {
        let needle = MediaResolver.normalize("law and order")
        XCTAssertEqual(MediaResolver.score(needle: needle, candidates: ["Law and Order SVU"]), 2)
        XCTAssertNil(MediaResolver.score(needle: needle, candidates: ["Lawrence of Arabia"]))
    }

    func testBestCandidateFieldWins() {
        // An episode matched by its series name must not be ranked on the
        // episode title, which usually has nothing to do with the phrase.
        let needle = MediaResolver.normalize("severance")
        let score = MediaResolver.score(
            needle: needle, candidates: ["Good News About Hell", "Severance", nil])
        XCTAssertEqual(score, 3)
    }
}
