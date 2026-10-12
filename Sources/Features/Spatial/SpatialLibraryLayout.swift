import Foundation
import simd

// Pure, deterministic layout math for the Atrium shelf.
// No SceneKit, no SwiftUI, no networking — unit-testable on its own.
//
// The library is one continuous shelf of cases racked spine-out, the way books
// actually sit on a shelf: you read the spines, and to see a cover you tip that
// one out toward you. World space: +X right, +Y up, the viewer looks down -Z.
//
// Cases pack by their thickness, so a shelf shows dozens at once. The shelf is a
// very gentle arc so the ends recede rather than running flat off the frame.
//
// There are no pages and no bays: item order runs strictly left to right, so
// "scroll right" always means "later in the library".

enum SpatialNavDirection {
    case previous, next
}

struct SpatialLayoutMetrics: Equatable {
    /// Case dimensions: cover width and height, and the spine thickness.
    var caseWidth: Float = 1.05
    var caseHeight: Float = 1.50
    var caseThickness: Float = 0.16
    /// Gap between neighbouring cases along the shelf. Cases stand spine-out,
    /// so they pack by their thickness and a shelf holds dozens.
    var caseGap: Float = 0.022

    /// Radius of the shelf arc. Gentle: enough that the ends of the run recede
    /// and turn slightly, not so much that spines become unreadable.
    var arcRadius: Float = 9.0
    /// Distance from the camera to the case at the focus.
    var focusDistance: Float = 3.90

    /// Height of the shelf's top surface, and of the case centres resting on it.
    var shelfSurfaceY: Float = 0
    var shelfBoardThickness: Float = 0.09
    /// How far the board reaches in front of and behind the cases.
    var shelfBoardDepth: Float = 0.28
    /// Back panel, measured radially inward from the case line.
    var backPanelInset: Float = 0.34
    var backPanelBottomY: Float = -2.30
    var backPanelTopY: Float = 2.70
    /// Underside of the shelf above, which closes the compartment over the row.
    var upperBoardY: Float = 1.80

    var cameraHeight: Float = 0.86
    var cameraPitchDegrees: Float = -2

    /// Cases kept mounted either side of the focus.
    var mountedRadius: Int = 22
    /// Cases either side of the focus that get cover art loaded — only the ones
    /// near enough to be tipped out can show a cover.
    var coverRadius: Int = 6
    /// Request the next page when this close to the end of the loaded items.
    var pageAheadItems: Int = 20

    /// Fingering through: the case under the focus tips out of the row toward
    /// the viewer, swinging its cover into view the way a book does when you
    /// hook it out with a finger. Neighbours take a fraction of it.
    var tiltOutYawDegrees: Float = -32
    var tiltOutForward: Float = 0.98
    var tiltOutRise: Float = 0.06

    /// Where a selected case flies to, relative to the camera, and how far it
    /// turns so both cover and spine read at once.
    var flyOutOffset: SIMD3<Float> = [-0.26, 0.08, -2.30]
    var flyOutYawDegrees: Float = -58
    var flyOutPitchDegrees: Float = 3

    /// Spacing between case centres measured along the arc. Spine-out, so it is
    /// the thickness that sets the pitch.
    var casePitch: Float { caseThickness + caseGap }
    /// Angle subtended by one case.
    var angularStep: Float { casePitch / arcRadius }
    var caseCentreY: Float { shelfSurfaceY + caseHeight / 2 }
}

/// A case's resolved place on the shelf, relative to the current focus.
struct SpatialSlot: Equatable {
    var itemIndex: Int
    /// Signed distance from the focused item, in cases.
    var offset: Int
    var angle: Float
    var position: SIMD3<Float>
    /// Rotation about Y from the arc alone. The tilt-out is applied on top.
    var yawRadians: Float
    /// 0 = square in the row, 1 = fully tipped out. Falls off either side of
    /// the focus so the row fans as you finger through it.
    var tilt: Float
}

struct SpatialLibraryLayout {
    var metrics: SpatialLayoutMetrics

    init(metrics: SpatialLayoutMetrics = SpatialLayoutMetrics()) {
        self.metrics = metrics
    }

    // MARK: - The arc

    /// The camera sits on the arc's axis of symmetry, `focusDistance` in front
    /// of the arc's nearest point.
    var cameraPosition: SIMD3<Float> {
        SIMD3<Float>(0, metrics.cameraHeight, arcNearZ + metrics.focusDistance)
    }

    /// z of the arc's nearest point, which is where the focused case stands.
    var arcNearZ: Float { 0 }

    /// Centre of curvature: behind the shelf, on the axis.
    var arcCentre: SIMD3<Float> {
        SIMD3<Float>(0, metrics.caseCentreY, arcNearZ - metrics.arcRadius)
    }

    /// Position of a case standing `offset` cases from the focus.
    func position(atOffset offset: Float) -> SIMD3<Float> {
        let angle = offset * metrics.angularStep
        let r = metrics.arcRadius
        return SIMD3<Float>(
            r * sin(angle),
            metrics.caseCentreY,
            arcNearZ - r + r * cos(angle))
    }

    /// Full placement for a loaded item, given which item currently has focus.
    /// `focus` is fractional so the shelf can glide between cases.
    func slot(forItemIndex index: Int, focus: Float) -> SpatialSlot {
        let offset = Float(index) - focus
        let angle = offset * metrics.angularStep
        return SpatialSlot(
            itemIndex: index,
            offset: Int(offset.rounded()),
            angle: angle,
            position: position(atOffset: offset),
            yawRadians: angle,
            tilt: tilt(atOffset: offset))
    }

    /// How far a case is tipped out of the row: only the one under the finger.
    /// A continuous fan would swing several cases through their neighbours,
    /// because a case is far deeper (its cover) than it is thick (its spine) —
    /// in the real thing you pull one book out at a time too.
    func tilt(atOffset offset: Float) -> Float {
        abs(offset) < 0.5 ? 1 : 0
    }

    /// The case pivots on its front-outer vertical edge, so it swings out of the
    /// row the way a book does when you hook a finger over its spine. Offset is
    /// in the case's own frame.
    var tiltPivotOffset: SIMD3<Float> {
        SIMD3<Float>(-metrics.caseThickness / 2, 0, metrics.caseWidth / 2)
    }

    /// Distance from the camera to a case at this offset — the depth cue that
    /// makes the shelf read as a curve rather than a flat strip.
    func distanceFromCamera(atOffset offset: Float) -> Float {
        simd_distance(position(atOffset: offset), cameraPosition)
    }

    // MARK: - Focus

    func clampedFocus(_ focus: Float, itemCount: Int) -> Float {
        guard itemCount > 0 else { return 0 }
        return min(max(focus, 0), Float(itemCount - 1))
    }

    /// Items mounted around the focus. Everything outside is recycled.
    func mountedRange(focus: Float, itemCount: Int) -> Range<Int> {
        guard itemCount > 0 else { return 0..<0 }
        let centre = Int(focus.rounded())
        let low = max(0, centre - metrics.mountedRadius)
        let high = min(itemCount - 1, centre + metrics.mountedRadius)
        guard low <= high else { return 0..<0 }
        return low..<(high + 1)
    }

    /// True when the focus is close enough to the end of the loaded items that
    /// the next page should be requested (the caller dedupes concurrent asks).
    func shouldRequestNextPage(focus: Float, loadedItemCount: Int, totalCount: Int?) -> Bool {
        guard loadedItemCount > 0 else { return false }
        if let totalCount, loadedItemCount >= totalCount { return false }
        return Float(loadedItemCount) - focus <= Float(metrics.pageAheadItems)
    }

    // MARK: - Navigation

    /// Sifting is one axis, so a step is simply the neighbouring item.
    func neighbourIndex(from index: Int, direction: SpatialNavDirection, itemCount: Int) -> Int? {
        guard itemCount > 0, index >= 0, index < itemCount else { return nil }
        let target = direction == .next ? index + 1 : index - 1
        guard target >= 0, target < itemCount else { return nil }
        return target
    }

    /// Converts a scroll delta in points into a change in focus, so a flick
    /// travels a predictable number of cases rather than a distance in metres.
    func focusDelta(forScrollPoints points: Float, precise: Bool) -> Float {
        let casesPerPoint: Float = precise ? 1.0 / 90.0 : 0.45
        return points * casesPerPoint
    }
}
