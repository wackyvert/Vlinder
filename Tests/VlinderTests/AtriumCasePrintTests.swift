import XCTest

/// What a case prints is worked out before any texture is rasterized, so the
/// rules can be checked here without SceneKit, CoreText, or a server.
final class AtriumCasePrintTests: XCTestCase {
    // MARK: - Films and shows

    func testAFilmWearsItsOwnPosterAndDatesItsSpine() {
        let casePrint = AtriumCasePrint.make(shape: .standard, name: "Heat", year: "1995")
        XCTAssertEqual(casePrint.jacket, .cover)
        XCTAssertEqual(casePrint.spineTitle, "Heat")
        XCTAssertEqual(casePrint.spineFootnote, "1995")
        XCTAssertNil(casePrint.bandTitle, "a poster already carries its own title")
    }

    // MARK: - Seasons

    func testASeasonWithArtOfItsOwnIsLeftUnprinted() {
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Season 2", year: "2009", hasOwnArtwork: true)
        XCTAssertEqual(casePrint.jacket, .cover)
        XCTAssertNil(casePrint.bandTitle)
    }

    func testASeasonBorrowingTheShowsPosterIsNamedOnIt() {
        // Otherwise a shelf of seasons is the same picture over and over.
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Season 2", year: "2009", hasOwnArtwork: false)
        XCTAssertEqual(casePrint.jacket, .bandedPoster)
        XCTAssertEqual(casePrint.bandTitle, "Season 2")
    }

    func testASeasonWithoutAYearCountsItsEpisodesInstead() {
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Specials", year: nil, childCount: 10)
        XCTAssertEqual(casePrint.spineFootnote, "10 episodes")
    }

    func testASeasonPrefersItsYearToItsCount() {
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Season 1", year: "2008", childCount: 7)
        XCTAssertEqual(casePrint.spineFootnote, "2008")
    }

    func testASingleEpisodeIsNotPluralised() {
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Season 1", year: nil, childCount: 1)
        XCTAssertEqual(casePrint.spineFootnote, "1 episode")
    }

    func testACountedNothingIsPrintedAsNothing() {
        let casePrint = AtriumCasePrint.make(
            shape: .season, name: "Season 1", year: nil, childCount: 0)
        XCTAssertNil(casePrint.spineFootnote)
    }

    // MARK: - Episodes

    func testAnEpisodeCarriesItsNumberOnBothSpineAndJacket() {
        let casePrint = AtriumCasePrint.make(
            shape: .episode, name: "Pilot", numberLabel: "S1 E1")
        XCTAssertEqual(casePrint.jacket, .still)
        XCTAssertEqual(casePrint.spineTitle, "Pilot")
        XCTAssertEqual(casePrint.spineFootnote, "S1 E1")
        XCTAssertEqual(casePrint.bandKicker, "S1 E1")
        XCTAssertEqual(casePrint.bandTitle, "Pilot")
    }

    func testAnEpisodeIsAlwaysPrinted() {
        // A wide still never fills a portrait jacket, and a still-less episode
        // must not fall back to a bare poster with nothing to identify it.
        for hasArt in [true, false] {
            let casePrint = AtriumCasePrint.make(
                shape: .episode, name: "Ozymandias",
                numberLabel: "S5 E14", hasOwnArtwork: hasArt)
            XCTAssertEqual(casePrint.jacket, .still)
            XCTAssertEqual(casePrint.bandTitle, "Ozymandias")
        }
    }

    func testAnUnnumberedEpisodeSimplyGoesWithout() {
        let casePrint = AtriumCasePrint.make(shape: .episode, name: "Untitled")
        XCTAssertNil(casePrint.spineFootnote)
        XCTAssertNil(casePrint.bandKicker)
        XCTAssertEqual(casePrint.bandTitle, "Untitled")
    }
}
