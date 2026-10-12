import Foundation
import SceneKit

/// One item on the shelf, as a physical case racked spine-out: a box carrying
/// its printed spine toward the viewer, its cover art on the outer face, and
/// plain shell stock elsewhere.
///
/// SceneKit orders an SCNBox's materials front, right, back, left, top, bottom.
/// The box is built thin across the shelf and deep into it, so "front" is the
/// spine you read and "right" is the cover that swings into view when the case
/// is tipped out.
///
/// The node's own origin sits on the case's front-outer vertical edge, so
/// rotating the node pivots the case about that edge — the way a book turns
/// when you hook a finger over its spine and pull.
final class SpatialCaseNode: SCNNode {
    static let hitTestCategory: Int = 1 << 3
    /// Non-interactive trim: rendered by the camera, excluded from hit tests.
    static let decorationCategory: Int = 1 << 4

    private enum Face: Int {
        case front = 0, right = 1, back = 2, left = 3, top = 4, bottom = 5
    }

    private(set) var itemId: String?
    private(set) var itemIndex: Int = -1
    private(set) var generation = UUID()
    private(set) var isFlownOut = false
    private(set) var hasCover = false

    private let bodyNode = SCNNode()
    private let badgeNode = SCNNode()
    private let fillNode = SCNNode()

    private var shelfPosition = SIMD3<Float>(0, 0, 0)
    private var shelfYaw: Float = 0
    private var caseWidth: CGFloat = 1.10
    private var caseHeight: CGFloat = 1.58
    private var caseThickness: CGFloat = 0.16
    private var restingTone = CGColor(gray: 1, alpha: 1)
    private var shellTone = CGColor(gray: 0.1, alpha: 1)

    override init() {
        super.init()
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildHierarchy() {
        categoryBitMask = Self.hitTestCategory

        // A slightly larger chamfer catches a specular edge, which is most of
        // what makes a box read as a moulded plastic case.
        let box = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.012)
        box.materials = (0..<6).map { _ in Self.shellMaterial() }
        // The printed faces are laminated card under a gloss wrap.
        box.materials[Face.front.rawValue] = Self.printMaterial(roughness: 0.36, lift: 0.20)
        box.materials[Face.right.rawValue] = Self.printMaterial(roughness: 0.28, lift: 0.62)
        bodyNode.geometry = box
        bodyNode.categoryBitMask = Self.hitTestCategory
        addChildNode(bodyNode)

        let badge = SCNPlane(width: 0.1, height: 0.1)
        badge.firstMaterial = Self.trimMaterial()
        badgeNode.geometry = badge
        badgeNode.opacity = 0
        badgeNode.categoryBitMask = Self.decorationCategory
        addChildNode(badgeNode)

        // Resume shows on the spine, where it reads without tipping the case out.
        let fill = SCNPlane(width: 0.1, height: 0.1)
        fill.firstMaterial = Self.trimMaterial()
        fillNode.geometry = fill
        fillNode.opacity = 0
        fillNode.categoryBitMask = Self.decorationCategory
        addChildNode(fillNode)
    }

    /// The moulded shell: matte polypropylene, no metalness.
    private static func shellMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.62
        material.metalness.contents = 0.0
        material.isDoubleSided = false
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        return material
    }

    /// Printed artwork under a gloss laminate.
    ///
    /// The art stays in `diffuse`, so it takes the room's light, its shading and
    /// its specular the way a real printed face does. A fraction of the same art
    /// is added through `emission` purely as a floor, so a face angled away from
    /// the light never sinks into shadow — the jacket is the thing you are
    /// trying to look at.
    private static func printMaterial(roughness: CGFloat, lift: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        material.isDoubleSided = false
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
        material.emission.intensity = lift
        return material
    }

    /// Small trim that should read at its own value regardless of the lighting.
    private static func trimMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        return material
    }

    // MARK: - Placement

    func configure(metrics: SpatialLayoutMetrics, pivotOffset: SIMD3<Float>) {
        caseWidth = CGFloat(metrics.caseWidth)
        caseHeight = CGFloat(metrics.caseHeight)
        caseThickness = CGFloat(metrics.caseThickness)

        (bodyNode.geometry as? SCNBox).map {
            $0.width = caseThickness
            $0.height = caseHeight
            $0.length = caseWidth
        }
        // Push the body off the node origin so the origin lands on the case's
        // front-outer edge, which is what it pivots about.
        bodyNode.simdPosition = -pivotOffset

        // A slim bar up the spine's foot, so progress reads while racked.
        let spineFaceZ = caseWidth / 2 + 0.003
        (fillNode.geometry as? SCNPlane).map {
            $0.width = caseThickness * 0.34
            $0.height = 0.04
        }
        fillNode.simdPosition = SIMD3<Float>(
            bodyNode.simdPosition.x,
            bodyNode.simdPosition.y - Float(caseHeight / 2 - 0.10),
            bodyNode.simdPosition.z + Float(spineFaceZ))
    }

    /// Stands the case in its slot, square in the row.
    func place(slot: SpatialSlot) {
        shelfPosition = slot.position
        shelfYaw = slot.yawRadians
        guard !isFlownOut else { return }
        simdPosition = shelfPosition
        simdOrientation = simd_quatf(angle: shelfYaw, axis: SIMD3<Float>(0, 1, 0))
    }

    @discardableResult
    func assign(item: BaseItem, index: Int, palette: AtriumPalette) -> UUID {
        generation = UUID()
        itemId = item.id
        itemIndex = index
        isFlownOut = false
        hasCover = false
        badgeNode.opacity = 0
        applyPalette(palette)
        setCover(nil)
        setSpine(nil)

        if let fraction = item.progressFraction {
            (fillNode.geometry as? SCNPlane)?.height = CGFloat(0.03 + 0.26 * Double(fraction))
            fillNode.opacity = 1
        } else {
            fillNode.opacity = 0
        }
        return generation
    }

    func clear() {
        generation = UUID()
        itemId = nil
        itemIndex = -1
        isFlownOut = false
        hasCover = false
        badgeNode.opacity = 0
        fillNode.opacity = 0
    }

    func applyPalette(_ palette: AtriumPalette) {
        guard let box = bodyNode.geometry as? SCNBox else { return }
        shellTone = palette.caseShell
        for face in [Face.back, .left, .top, .bottom] {
            box.materials[face.rawValue].diffuse.contents = palette.caseShell
        }
        if !hasCover {
            box.materials[Face.right.rawValue].diffuse.contents = palette.caseShell
        }
        fillNode.geometry?.firstMaterial?.diffuse.contents = palette.accent
        restingTone = palette.isDark
            ? CGColor(gray: 0.95, alpha: 1)
            : CGColor(gray: 1.0, alpha: 1)
        box.materials[Face.front.rawValue].multiply.contents = restingTone
        box.materials[Face.right.rawValue].multiply.contents = restingTone
    }

    private func setCover(_ image: CGImage?) {
        guard let box = bodyNode.geometry as? SCNBox else { return }
        let material = box.materials[Face.right.rawValue]
        // Diffuse keeps the art lit by the room; emission adds a fraction of the
        // same art underneath so the face never sinks into shadow.
        material.diffuse.contents = image ?? shellTone
        material.emission.contents = image
        hasCover = image != nil
    }

    private func setSpine(_ image: CGImage?) {
        guard let box = bodyNode.geometry as? SCNBox else { return }
        let material = box.materials[Face.front.rawValue]
        material.diffuse.contents = image ?? shellTone
        material.emission.contents = image
    }

    // MARK: - Texture application (generation-guarded)

    func applyCover(_ image: CGImage, generation token: UUID) {
        guard token == generation else { return }
        setCover(image)
    }

    func applySpine(_ image: CGImage, generation token: UUID) {
        guard token == generation else { return }
        setSpine(image)
    }

    func applyBadge(_ image: CGImage, aspect: CGFloat, generation token: UUID) {
        guard token == generation else { return }
        let width = caseThickness * 0.66
        (badgeNode.geometry as? SCNPlane).map {
            $0.width = width
            $0.height = width / aspect
        }
        badgeNode.simdPosition = SIMD3<Float>(
            bodyNode.simdPosition.x,
            bodyNode.simdPosition.y + Float(caseHeight / 2 - 0.12),
            bodyNode.simdPosition.z + Float(caseWidth / 2 + 0.004))
        badgeNode.geometry?.firstMaterial?.diffuse.contents = image
        badgeNode.opacity = 1
    }

    // MARK: - Tipping out and flying out

    /// Hooks the case out of the row: it slides forward off the shelf and swings
    /// about its front edge, bringing the cover round toward the viewer.
    func setTilted(_ tilted: Bool, metrics: SpatialLayoutMetrics, reduceMotion: Bool) {
        guard !isFlownOut else { return }
        let yaw = shelfYaw + (tilted ? metrics.tiltOutYawDegrees * .pi / 180 : 0)
        let forward = tilted ? metrics.tiltOutForward : 0
        let rise = tilted ? metrics.tiltOutRise : 0
        // Forward is along the case's own facing, so a tipped case on the far
        // end of the arc comes out toward the viewer, not sideways.
        let facing = simd_quatf(angle: shelfYaw, axis: SIMD3<Float>(0, 1, 0))
            .act(SIMD3<Float>(0, 0, forward))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.26
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        simdPosition = shelfPosition + facing + SIMD3<Float>(0, rise, 0)
        simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        SCNTransaction.commit()
    }

    /// Lifts the case clear of the shelf and presents the jacket.
    func flyOut(to transform: (position: SIMD3<Float>, orientation: simd_quatf),
                reduceMotion: Bool) {
        isFlownOut = true
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.44
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        simdPosition = transform.position
        simdOrientation = transform.orientation
        setTone(CGColor(gray: 1.0, alpha: 1))
        SCNTransaction.commit()
    }

    func returnToShelf(reduceMotion: Bool) {
        guard isFlownOut else { return }
        isFlownOut = false
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.36
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        simdPosition = shelfPosition
        simdOrientation = simd_quatf(angle: shelfYaw, axis: SIMD3<Float>(0, 1, 0))
        setTone(restingTone)
        SCNTransaction.commit()
    }

    /// Cases still racked step back while one is in hand.
    func setDimmed(_ dimmed: Bool) {
        guard !isFlownOut else { return }
        setTone(dimmed ? CGColor(gray: 0.5, alpha: 1) : restingTone)
    }

    /// `multiply` scales a material's whole output, emission included, so this
    /// dims the printed faces as well as the lit shell.
    /// `multiply` scales a material's whole output, emission included, so this
    /// dims the printed faces as well as the lit shell.
    private func setTone(_ tone: CGColor) {
        guard let box = bodyNode.geometry as? SCNBox else { return }
        box.materials[Face.front.rawValue].multiply.contents = tone
        box.materials[Face.right.rawValue].multiply.contents = tone
    }
}
