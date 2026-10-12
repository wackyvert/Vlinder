import XCTest

/// The URL vocabulary is the contract between the Top Shelf, the Siri handler,
/// and `xcrun simctl openurl`; if it drifts, every one of those breaks silently.
final class DeepLinkTests: XCTestCase {
    func testParsesPlayAndTune() {
        XCTAssertEqual(DeepLink(url: URL(string: "vlinder://play/abc123")!), .play(itemId: "abc123"))
        XCTAssertEqual(DeepLink(url: URL(string: "vlinder://tune/ch-9")!), .tune(channelId: "ch-9"))
    }

    func testRoundTrips() {
        for link in [DeepLink.play(itemId: "a1"), .tune(channelId: "b2")] {
            XCTAssertEqual(DeepLink(url: link.url), link)
        }
    }

    func testRejectsForeignAndIncompleteURLs() {
        XCTAssertNil(DeepLink(url: URL(string: "https://play/abc")!))
        XCTAssertNil(DeepLink(url: URL(string: "vlinder://play")!))
        XCTAssertNil(DeepLink(url: URL(string: "vlinder://play/")!))
        XCTAssertNil(DeepLink(url: URL(string: "vlinder://open/abc")!))
    }
}
