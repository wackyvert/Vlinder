import Foundation
import simd

// Pure, deterministic layout math for the Live TV wall.
// No SceneKit, no SwiftUI, no networking — unit-testable on its own.
//
// Where the library Atrium is a shelf you finger along, the Live TV Atrium is a
// room you stand in the middle of: the channels wrap around the viewer on the
// inside of a cylinder, one band per lineup group, so "look left" is earlier in
// the group and "look up" is another kind of television altogether.
//
// World space: +X right, +Y up, the viewer looks down -Z from the origin. The
// wall is concave — its axis runs vertically through the camera — so every card
// is the same distance away and none of them have to be read edge-on.

enum LiveWallNavDirection {
    case left, right, up, down
}

struct LiveWallMetrics: Equatable {
    /// Card face. Slightly wider than the 16:9 picture it carries, because the
    /// chrome along its foot is part of the card and not an overlay on the
    /// programme — a still gets centre-cropped into it.
    var cardWidth: Float = 1.28
    var cardHeight: Float = 0.91
    /// Gap between neighbouring cards along a band.
    var cardGap: Float = 0.12

    /// How far the wall is let off the perfect cylinder, 0 for a cylinder
    /// centred on the eye and 1 for a flat plane.
    ///
    /// A cylinder centred on the eye is the one shape where curvature cannot
    /// be seen: every card is the same distance away and every card faces the
    /// viewer dead on, so the run reads as a flat strip however far it wraps.
    /// Letting the wall off that circle toward a plane is what makes the outer
    /// cards turn away and stand further off — which is the whole of what
    /// "curved" looks like from inside.
    var flatness: Float = 0.80

    /// Radius of the wall.
    var radius: Float = 5.90

    /// Vertical distance between band centres, and the height of the band the
    /// viewer is looking straight at. The bands are set well apart: the dark
    /// lane between them, with its light line, is what makes the wall read as
    /// stacked rows rather than as a grid.
    var rowPitch: Float = 1.37
    var focusRowY: Float = 0.02

    /// The focused card grows and steps off the wall toward the viewer, and
    /// pushes its neighbours aside to make the room for itself.
    var focusScale: Float = 1.82
    var focusForward: Float = 0.30
    /// How much of the growth the immediate neighbours give up as extra gap.
    var focusSpread: Float = 1.0
    /// How far a card shrinks as it runs away from the focus along its band.
    /// Scale is what carries focus on a ten-foot interface; a bezel alone
    /// cannot do it, and cards that all stay the same size read as a grid.
    var columnRecession: Float = 0.28
    var recessionSpan: Float = 3.0

    /// A band the viewer is not looking at sits back and goes quiet.
    var offRowScale: Float = 0.995
    var offRowDim: Float = 0.82
    /// Cards this far either side of the band's focus have faded out entirely.
    var columnFadeSpan: Float = 6.2
    /// Faintest a mounted card is allowed to get before it is simply cut.
    var minimumBrightness: Float = 0.14

    /// Bands tip to face the eye, so the top band looks down and the bottom
    /// band looks up rather than presenting themselves flat to the ceiling.
    var rowPitchPerMetre: Float = 0.46
    var maximumRowPitchRadians: Float = 0.38

    /// The group plate is pinned at the left edge of the view rather than
    /// scrolling with the band — it labels the band, it is not part of it.
    var plateAngleRadians: Float = -0.560
    var plateWidth: Float = 0.88
    var plateHeight: Float = 0.91
    /// The plate stands slightly proud of the wall so its edge catches light.
    var plateForward: Float = 0.40
    /// Clear space between the plate's inner edge and the first card of its run.
    var plateGutter: Float = 0.11

    /// The eye is above the coffee table and tipped a little toward the floor,
    /// which is how a person on a sofa actually sees a wall: enough of the
    /// floor comes into frame to carry the wall's reflection and the furniture.
    var cameraHeight: Float = 0.55
    var cameraPitchDegrees: Float = -7

    /// Where the floor is, measured from the focused band. Fixed: the floor
    /// does not move when you change band, the wall does.
    var floorBelowFocus: Float = 2.18
    /// Horizontal field of view. Wide enough that a band runs out past both
    /// edges of the frame — the wall should never look like it ends.
    var fieldOfViewDegrees: Float = 79

    /// Cards kept mounted either side of a band's focus, and bands kept mounted
    /// either side of the focused band.
    var mountedColumnRadius: Int = 5
    var mountedRowRadius: Int = 2
    /// Cards either side of the focus that get real programme artwork.
    var artworkColumnRadius: Int = 4

    /// Card face aspect, which the printed texture is drawn to.
    var cardAspect: Float { cardWidth / cardHeight }

    /// Angle subtended by one card, before any focus spreading.
    var angularStep: Float { (cardWidth + cardGap) / radius }
    /// Extra half-gap the focused card claims from each neighbour.
    var focusSpreadAngle: Float {
        ((focusScale - 1) * cardWidth * focusSpread) / (2 * radius)
    }
}

/// A card's resolved place on the wall, relative to the current focus.
struct LiveWallSlot: Equatable {
    var rowIndex: Int
    var columnIndex: Int
    /// Signed distance from the band's focus, in cards, and from the focused
    /// band, in bands. Fractional while the wall is gliding.
    var columnOffset: Float
    var rowOffset: Float

    var position: SIMD3<Float>
    var yawRadians: Float
    var pitchRadians: Float
    var scale: Float
    /// 1 = the card the viewer is on, 0 = nowhere near it. Drives glow.
    var focusWeight: Float
    /// 0…1 multiplier on how brightly the card is lit.
    var brightness: Float
    var isFocused: Bool { focusWeight > 0.5 }
}

struct LiveWallLayout {
    var metrics: LiveWallMetrics

    init(metrics: LiveWallMetrics = LiveWallMetrics()) {
        self.metrics = metrics
    }

    // MARK: - The cylinder

    /// The eye sits on the cylinder's axis, so the wall wraps around it.
    var cameraPosition: SIMD3<Float> {
        SIMD3<Float>(0, metrics.cameraHeight, 0)
    }

    /// Angle of a card sitting `offset` cards from its band's focus. The
    /// focused card claims a little extra room, and everything beyond the
    /// neighbours simply shifts along rather than fanning further apart.
    func angle(atColumnOffset offset: Float) -> Float {
        offset * metrics.angularStep
            + metrics.focusSpreadAngle * clamp(offset, -1, 1)
    }

    /// Height of a band sitting `offset` bands from the focused band. Bands
    /// below the focus have the larger index, so they hang lower.
    func height(atRowOffset offset: Float) -> Float {
        metrics.focusRowY - offset * metrics.rowPitch
    }

    /// Where a card sits, and which way it points, for a given angle along the
    /// run. Both are blended between the pure cylinder and the flat wall by
    /// `flatness`, so the two stay consistent with each other.
    func wallPoint(atAngle theta: Float) -> (position: SIMD2<Float>, yaw: Float) {
        let r = metrics.radius
        let f = clamp(metrics.flatness, 0, 1)
        // On the plane the run keeps its arc length, so cards neither bunch up
        // nor spread out as the wall is flattened — they just move back.
        let arc = SIMD2<Float>(r * sin(theta), -r * cos(theta))
        let flat = SIMD2<Float>(r * theta, -r)
        return (arc + (flat - arc) * f, -theta * (1 - f))
    }

    /// Position of a card's centre on the wall, before it steps forward.
    func wallPosition(columnOffset: Float, rowOffset: Float) -> SIMD3<Float> {
        let point = wallPoint(atAngle: angle(atColumnOffset: columnOffset))
        return SIMD3<Float>(point.position.x, height(atRowOffset: rowOffset), point.position.y)
    }

    /// How strongly a card holds the focus: 1 at the centre of the focused
    /// band, easing away in both axes so the glow travels with the eye.
    func focusWeight(columnOffset: Float, rowOffset: Float) -> Float {
        let column = smoothFalloff(abs(columnOffset), edge: 1)
        let row = smoothFalloff(abs(rowOffset), edge: 1)
        return column * row
    }

    /// Full placement for one card.
    func slot(row: Int, column: Int, rowFocus: Float, columnFocus: Float) -> LiveWallSlot {
        let columnOffset = Float(column) - columnFocus
        let rowOffset = Float(row) - rowFocus
        let weight = focusWeight(columnOffset: columnOffset, rowOffset: rowOffset)

        let theta = angle(atColumnOffset: columnOffset)
        let point = wallPoint(atAngle: theta)
        var position = SIMD3<Float>(
            point.position.x, height(atRowOffset: rowOffset), point.position.y)
        // Stepping forward means moving along the card's own normal, which on a
        // flattened wall is not the same as pointing at the axis.
        let inward = SIMD3<Float>(-sin(point.yaw), 0, cos(point.yaw))
        position += inward * (metrics.focusForward * weight)

        // Away from the focus a card recedes as well as dims, so the wall has
        // depth along its own length rather than reading as a flat grid.
        let recession = 1 - metrics.columnRecession
            * min(abs(columnOffset), metrics.recessionSpan) / metrics.recessionSpan
        let scale = (metrics.offRowScale
            + (metrics.focusScale - metrics.offRowScale) * weight) * recession

        return LiveWallSlot(
            rowIndex: row,
            columnIndex: column,
            columnOffset: columnOffset,
            rowOffset: rowOffset,
            position: position,
            yawRadians: point.yaw,
            pitchRadians: pitch(forHeight: position.y),
            scale: scale,
            focusWeight: weight,
            brightness: brightness(columnOffset: columnOffset, rowOffset: rowOffset))
    }

    /// Where a band's group plate stands: pinned at the left of the view, at
    /// the band's own height, tipped to face the eye like everything else.
    func plateSlot(row: Int, rowFocus: Float) -> LiveWallSlot {
        let rowOffset = Float(row) - rowFocus
        // The plate is the head cell of its band, so it sits on the same wall,
        // at the same height, turned the same way as the cards it leads.
        let point = wallPoint(atAngle: metrics.plateAngleRadians)
        var position = SIMD3<Float>(
            point.position.x, height(atRowOffset: rowOffset), point.position.y)
        position += SIMD3<Float>(-sin(point.yaw), 0, cos(point.yaw)) * metrics.plateForward

        let onFocusedRow = smoothFalloff(abs(rowOffset), edge: 1)
        return LiveWallSlot(
            rowIndex: row,
            columnIndex: -1,
            columnOffset: 0,
            rowOffset: rowOffset,
            position: position,
            yawRadians: point.yaw,
            // No pitch. The bands tip to face the eye, but a rail of plates has
            // to be one family: pitching each to its own height gives the three
            // of them three different shears, and their type three different
            // slants, which is exactly what stops them reading as a set.
            pitchRadians: 0,
            scale: 1,
            focusWeight: onFocusedRow,
            brightness: max(metrics.offRowDim, rowBrightness(rowOffset)))
    }

    /// Height of the floor, in world space.
    var floorY: Float { metrics.focusRowY - metrics.floorBelowFocus }

    /// Height of the light line that separates a band from the one below it.
    func separatorHeight(belowRow row: Int, rowFocus: Float) -> Float {
        let upper = height(atRowOffset: Float(row) - rowFocus)
        let lower = height(atRowOffset: Float(row + 1) - rowFocus)
        return (upper + lower) / 2
    }

    /// Bands tip to face the eye. Straight ahead is flat; the further a band
    /// is above or below the eye, the more it turns back toward it.
    func pitch(forHeight y: Float) -> Float {
        let raw = (y - metrics.focusRowY) * metrics.rowPitchPerMetre
        return clamp(raw, -metrics.maximumRowPitchRadians, metrics.maximumRowPitchRadians)
    }

    // MARK: - Light falloff

    /// How brightly a card is lit: it fades along its band away from the focus,
    /// and a whole band dims when the viewer is looking at another one.
    ///
    /// The run also stops dead at the plate. The plate is the head of its band,
    /// not a label dropped on top of it, so nothing belonging to the band is
    /// allowed to appear to its left — which is also what stops a card from
    /// sliding out from behind it as the wall scrolls.
    func brightness(columnOffset: Float, rowOffset: Float) -> Float {
        let column = smoothFalloff(abs(columnOffset), edge: metrics.columnFadeSpan)
        let lit = max(metrics.minimumBrightness, column * rowBrightness(rowOffset))
        return lit * pastThePlate(columnOffset: columnOffset)
    }

    /// Angle at which the band's run may begin: the plate's inner edge plus a
    /// gutter the width of the gap between two cards.
    var runStartAngle: Float {
        metrics.plateAngleRadians
            + (metrics.plateWidth / 2 + metrics.plateGutter) / metrics.radius
    }

    /// 1 where a card is clear of the plate, easing to 0 as it runs behind it.
    func pastThePlate(columnOffset: Float) -> Float {
        let theta = angle(atColumnOffset: columnOffset)
        let over = (theta - runStartAngle) / max(metrics.angularStep, 0.0001)
        return clamp(over, 0, 1)
    }

    private func rowBrightness(_ rowOffset: Float) -> Float {
        let onFocus = smoothFalloff(abs(rowOffset), edge: 1.9)
        return metrics.offRowDim + (1 - metrics.offRowDim) * onFocus
    }

    // MARK: - What is mounted

    func mountedColumns(columnFocus: Float, columnCount: Int) -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        let centre = Int(columnFocus.rounded())
        var low = max(0, centre - metrics.mountedColumnRadius)
        let high = min(columnCount - 1, centre + metrics.mountedColumnRadius)
        // A card fully behind the plate is not dim, it is not there: mounting
        // it costs a draw call for something nobody can see.
        while low < high, pastThePlate(columnOffset: Float(low) - columnFocus) <= 0 {
            low += 1
        }
        guard low <= high else { return 0..<0 }
        return low..<(high + 1)
    }

    func mountedRows(rowFocus: Float, rowCount: Int) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let centre = Int(rowFocus.rounded())
        let low = max(0, centre - metrics.mountedRowRadius)
        let high = min(rowCount - 1, centre + metrics.mountedRowRadius)
        guard low <= high else { return 0..<0 }
        return low..<(high + 1)
    }

    /// Cards near enough the focus to be worth fetching programme stills for.
    func wantsArtwork(columnOffset: Float, rowOffset: Float) -> Bool {
        abs(columnOffset) <= Float(metrics.artworkColumnRadius) && abs(rowOffset) <= 2.001
    }

    // MARK: - Navigation

    func clampedFocus(_ focus: Float, count: Int) -> Float {
        guard count > 0 else { return 0 }
        return min(max(focus, 0), Float(count - 1))
    }

    /// A step is simply the neighbouring card, or the neighbouring band.
    func neighbour(from index: Int, forward: Bool, count: Int) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        let target = forward ? index + 1 : index - 1
        guard target >= 0, target < count else { return nil }
        return target
    }

    /// Converts a scroll delta in points into a change in focus, so a flick
    /// travels a predictable number of cards rather than a distance in metres.
    func focusDelta(forScrollPoints points: Float, precise: Bool) -> Float {
        let cardsPerPoint: Float = precise ? 1.0 / 150.0 : 0.30
        return points * cardsPerPoint
    }
}

// MARK: - Small maths

/// 1 at zero, 0 at `edge`, with an ease in between — no corners for the eye to
/// catch as the wall glides.
func smoothFalloff(_ distance: Float, edge: Float) -> Float {
    guard edge > 0 else { return distance <= 0 ? 1 : 0 }
    let t = clamp(distance / edge, 0, 1)
    let eased = 1 - t
    return eased * eased * (3 - 2 * eased)
}

func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
    min(max(value, low), high)
}
