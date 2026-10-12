import XCTest
import simd

/// Pure-math contract tests for the Atrium shelf. The layout source file is
/// compiled directly into this bundle, so no app host or rendering is needed.
final class SpatialLibraryLayoutTests: XCTestCase {
    let layout = SpatialLibraryLayout()
    var metrics: SpatialLayoutMetrics { layout.metrics }

    // MARK: - The arc

    func testFocusedCaseIsCentredAndSquareToTheCamera() {
        let slot = layout.slot(forItemIndex: 7, focus: 7)
        XCTAssertEqual(slot.position.x, 0, accuracy: 0.0001)
        XCTAssertEqual(slot.yawRadians, 0, accuracy: 0.0001)
        XCTAssertEqual(slot.offset, 0)
    }

    func testCasesRunLeftToRightInItemOrder() {
        // The whole point of the shelf: later items are always further right.
        let positions = (0..<9).map { layout.slot(forItemIndex: $0, focus: 4).position.x }
        for pair in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1, "item order must run left to right")
        }
    }

    func testNeighboursRecedeFromTheCamera() {
        // Depth is what makes this a shelf rather than a flat strip.
        var previous = layout.distanceFromCamera(atOffset: 0)
        for offset in 1...metrics.mountedRadius {
            let distance = layout.distanceFromCamera(atOffset: Float(offset))
            XCTAssertGreaterThan(distance, previous)
            previous = distance
        }
    }

    func testTheCurveProducesRealDepth() {
        // Guards against the shelf being flattened back into a poster wall:
        // the far end of the mounted window must be meaningfully smaller.
        let near = layout.distanceFromCamera(atOffset: 0)
        let far = layout.distanceFromCamera(atOffset: Float(metrics.mountedRadius))
        XCTAssertGreaterThan(far - near, 1.2, "not enough depth across the shelf")
        XCTAssertLessThan(near / far, 0.80, "cases barely change size — the shelf is flat")
    }

    func testShelfShowsSpinesNotCovers() {
        // Racked spine-out: the pitch is set by the case's thickness, so a shelf
        // shows dozens at once rather than a handful of covers.
        XCTAssertEqual(metrics.casePitch, metrics.caseThickness + metrics.caseGap, accuracy: 0.0001)
        XCTAssertLessThan(metrics.casePitch, metrics.caseWidth / 3)
    }

    func testOnlyTheCaseUnderTheFingerTipsOut() {
        // A continuous fan would swing cases through their neighbours.
        XCTAssertEqual(layout.tilt(atOffset: 0), 1)
        XCTAssertEqual(layout.tilt(atOffset: 0.4), 1)
        XCTAssertEqual(layout.tilt(atOffset: 1), 0)
        XCTAssertEqual(layout.tilt(atOffset: -3), 0)
    }

    func testTippedCaseClearsTheRowItCameFrom() {
        // The case pivots on its front edge and must end up entirely in front of
        // its neighbours, or it renders intersecting them.
        let yaw = metrics.tiltOutYawDegrees * .pi / 180
        let pivotZ = metrics.caseWidth / 2 + metrics.tiltOutForward
        // Relative to its pivot the body spans z in [-caseWidth, 0], so the
        // deepest corner after rotating lands at -caseWidth * cos(yaw).
        let backCornerZ = -metrics.caseWidth * cos(yaw)
        XCTAssertGreaterThan(pivotZ + backCornerZ, metrics.caseWidth / 2,
                             "a tipped case would intersect the row")
    }

    func testRackedCasesNeverIntersect() {
        // Neighbours are spaced by their spine thickness plus the gap.
        let a = layout.position(atOffset: 0)
        let b = layout.position(atOffset: 1)
        XCTAssertGreaterThan(simd_distance(a, b), metrics.caseThickness)
    }

    func testSlotsAreDeterministic() {
        for index in [0, 3, 12, 97] {
            XCTAssertEqual(
                layout.slot(forItemIndex: index, focus: 5),
                layout.slot(forItemIndex: index, focus: 5))
        }
    }

    func testShelfGlidesSmoothlyBetweenCases() {
        // A fractional focus must land between the two whole positions, so
        // sifting is continuous rather than snapping case to case.
        let atFour = layout.slot(forItemIndex: 6, focus: 4).position.x
        let atHalf = layout.slot(forItemIndex: 6, focus: 4.5).position.x
        let atFive = layout.slot(forItemIndex: 6, focus: 5).position.x
        XCTAssertLessThan(atHalf, atFour)
        XCTAssertGreaterThan(atHalf, atFive)
    }

    // MARK: - Focus and windowing

    func testFocusClamping() {
        XCTAssertEqual(layout.clampedFocus(-4, itemCount: 30), 0)
        XCTAssertEqual(layout.clampedFocus(99, itemCount: 30), 29)
        XCTAssertEqual(layout.clampedFocus(12, itemCount: 30), 12)
        XCTAssertEqual(layout.clampedFocus(5, itemCount: 0), 0)
    }

    func testMountedWindowFollowsTheFocus() {
        let r = metrics.mountedRadius
        XCTAssertEqual(layout.mountedRange(focus: 0, itemCount: 100), 0..<(r + 1))
        XCTAssertEqual(layout.mountedRange(focus: 40, itemCount: 100), (40 - r)..<(41 + r))
        XCTAssertEqual(layout.mountedRange(focus: 99, itemCount: 100), (99 - r)..<100)
        XCTAssertTrue(layout.mountedRange(focus: 0, itemCount: 0).isEmpty)
    }

    func testMountedWindowStaysSmallForHugeLibraries() {
        let window = layout.mountedRange(focus: 2_500, itemCount: 5_000)
        XCTAssertEqual(window.count, metrics.mountedRadius * 2 + 1)
    }

    // MARK: - Paging

    func testNextPageTrigger() {
        XCTAssertFalse(layout.shouldRequestNextPage(focus: 0, loadedItemCount: 100, totalCount: 500))
        XCTAssertFalse(layout.shouldRequestNextPage(focus: 60, loadedItemCount: 100, totalCount: 500))
        XCTAssertTrue(layout.shouldRequestNextPage(focus: 81, loadedItemCount: 100, totalCount: 500))
        XCTAssertFalse(layout.shouldRequestNextPage(focus: 99, loadedItemCount: 100, totalCount: 100))
        XCTAssertFalse(layout.shouldRequestNextPage(focus: 0, loadedItemCount: 0, totalCount: nil))
        XCTAssertTrue(layout.shouldRequestNextPage(focus: 90, loadedItemCount: 100, totalCount: nil))
    }

    // MARK: - Navigation

    func testSteppingIsSimplyTheNeighbouringItem() {
        XCTAssertEqual(layout.neighbourIndex(from: 5, direction: .next, itemCount: 100), 6)
        XCTAssertEqual(layout.neighbourIndex(from: 5, direction: .previous, itemCount: 100), 4)
    }

    func testSteppingStopsAtTheEndsOfTheShelf() {
        XCTAssertNil(layout.neighbourIndex(from: 0, direction: .previous, itemCount: 100))
        XCTAssertNil(layout.neighbourIndex(from: 99, direction: .next, itemCount: 100))
        XCTAssertNil(layout.neighbourIndex(from: 0, direction: .next, itemCount: 0))
        XCTAssertNil(layout.neighbourIndex(from: 200, direction: .next, itemCount: 100))
    }

    func testScrollingTravelsAPredictableNumberOfCases() {
        // A trackpad flick of a few hundred points should move a handful of
        // cases, not the whole library and not a fraction of one.
        let flick = layout.focusDelta(forScrollPoints: 270, precise: true)
        XCTAssertEqual(flick, 3, accuracy: 0.5)
        // A mouse wheel reports a couple of line units per notch.
        let notch = layout.focusDelta(forScrollPoints: 3, precise: false)
        XCTAssertGreaterThan(notch, 0.5)
        XCTAssertLessThan(notch, 3)
    }

    func testScrollDirectionIsSigned() {
        XCTAssertLessThan(layout.focusDelta(forScrollPoints: -120, precise: true), 0)
        XCTAssertGreaterThan(layout.focusDelta(forScrollPoints: 120, precise: true), 0)
    }

    // MARK: - Furniture

    func testCasesStandOnTheShelfSurface() {
        XCTAssertEqual(metrics.caseCentreY, metrics.shelfSurfaceY + metrics.caseHeight / 2, accuracy: 0.0001)
        XCTAssertLessThan(metrics.backPanelBottomY, metrics.shelfSurfaceY)
        XCTAssertGreaterThan(metrics.backPanelTopY, metrics.caseCentreY + metrics.caseHeight / 2)
    }

    func testCameraLooksAtTheCasesNotOverThem() {
        let camera = layout.cameraPosition
        XCTAssertGreaterThan(camera.y, metrics.shelfSurfaceY)
        XCTAssertLessThan(camera.y, metrics.caseCentreY + metrics.caseHeight / 2)
        XCTAssertEqual(camera.z - layout.arcNearZ, metrics.focusDistance, accuracy: 0.0001)
    }
}
