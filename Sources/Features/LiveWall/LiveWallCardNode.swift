import Foundation
import SceneKit

/// One channel on the wall: a lit panel showing what is on that channel now,
/// with a bloom behind it that only the focused card turns up.
///
/// A card is a screen, so it is shaded `.constant` — the room's lights do not
/// fall on it, it emits. Dimming a card away from the focus is therefore done
/// by multiplying its own texture down rather than by taking light away.
final class LiveWallCardNode: SCNNode {
    static let hitTestCategory: Int = 1 << 5
    static let decorationCategory: Int = 1 << 6

    private(set) var cardId: String?
    private(set) var rowIndex: Int = -1
    private(set) var columnIndex: Int = -1
    private(set) var generation = UUID()
    private(set) var hasArtwork = false

    private let faceNode = SCNNode()
    private let glowNode = SCNNode()

    private var cardWidth: CGFloat = 1
    private var cardHeight: CGFloat = 1
    private var brightness: Float = 1

    override init() {
        super.init()
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildHierarchy() {
        categoryBitMask = Self.hitTestCategory

        let glow = SCNPlane(width: 1, height: 1)
        glow.firstMaterial = LiveWallGeometry.emissiveMaterial(blend: .add)
        glowNode.geometry = glow
        glowNode.opacity = 0
        glowNode.categoryBitMask = Self.decorationCategory
        // Behind the face, but only just: the bloom is light spilling onto the
        // wall around the card, not a halo floating off it.
        glowNode.position = SCNVector3(0, 0, -0.012)
        addChildNode(glowNode)

        let face = SCNPlane(width: 1, height: 1)
        face.firstMaterial = LiveWallGeometry.emissiveMaterial()
        face.firstMaterial?.diffuse.contents = LiveWallCardNode.blankFace
        faceNode.geometry = face
        faceNode.categoryBitMask = Self.hitTestCategory
        addChildNode(faceNode)
    }

    // MARK: - Placement

    func configure(metrics: LiveWallMetrics) {
        cardWidth = CGFloat(metrics.cardWidth)
        cardHeight = CGFloat(metrics.cardHeight)

        (faceNode.geometry as? SCNPlane).map {
            $0.width = cardWidth
            $0.height = cardHeight
        }
        // The bloom reaches a little past every edge — light spilling off a
        // lit bezel, not a panel of its own behind the card.
        (glowNode.geometry as? SCNPlane).map {
            $0.width = cardWidth * 1.30
            $0.height = cardHeight * 1.44
        }
    }

    /// Puts the card where the layout says it goes. Yaw turns it around the
    /// wall, pitch tips it back toward the eye.
    func place(slot: LiveWallSlot) {
        simdPosition = slot.position
        simdOrientation = simd_quatf(angle: slot.yawRadians, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: slot.pitchRadians, axis: SIMD3<Float>(1, 0, 0))
        simdScale = SIMD3<Float>(repeating: slot.scale)

        setBrightness(slot.brightness)
        // Only the focused card blooms, and a fully transparent plane still
        // costs a draw call — take it out of the scene instead.
        glowNode.opacity = CGFloat(slot.focusWeight) * 0.62
        glowNode.isHidden = slot.focusWeight < 0.02
    }

    // MARK: - Contents

    /// Points the node at a card and hands back the token a print for it must
    /// carry. Whether the old face is kept is the caller's call: a card being
    /// reprinted for a change of emphasis keeps showing what it showed — a
    /// texture-less constant material renders pure white, and a wall of white
    /// rectangles on every key press is exactly what that looks like.
    @discardableResult
    func assign(card: LiveWallCard, row: Int, column: Int, keepingFace: Bool) -> UUID {
        cardId = card.id
        rowIndex = row
        columnIndex = column
        generation = UUID()
        hasArtwork = false
        if !keepingFace {
            faceNode.geometry?.firstMaterial?.diffuse.contents = LiveWallCardNode.blankFace
        }
        return generation
    }

    /// What a card shows before its face has been printed: the wall's own dark
    /// ground, never the material default.
    static var blankFace: Any = CGColor(srgbRed: 0.085, green: 0.098, blue: 0.165, alpha: 1)

    func clear() {
        cardId = nil
        rowIndex = -1
        columnIndex = -1
        generation = UUID()
        hasArtwork = false
        faceNode.geometry?.firstMaterial?.diffuse.contents = LiveWallCardNode.blankFace
        glowNode.geometry?.firstMaterial?.diffuse.contents = nil
        glowNode.opacity = 0
    }

    func applyFace(_ image: CGImage, hasArtwork: Bool, generation token: UUID) {
        guard token == generation else { return }
        faceNode.geometry?.firstMaterial?.diffuse.contents = image
        self.hasArtwork = hasArtwork
    }

    func applyGlow(_ image: CGImage, generation token: UUID) {
        guard token == generation else { return }
        glowNode.geometry?.firstMaterial?.diffuse.contents = image
    }

    /// Cards away from the focus are multiplied down rather than lit less —
    /// they are emitting, so there is no light to take away.
    func setBrightness(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - brightness) > 0.002 else { return }
        brightness = clamped
        faceNode.geometry?.firstMaterial?.multiply.contents =
            CGColor(gray: CGFloat(clamped), alpha: 1)
    }
}
