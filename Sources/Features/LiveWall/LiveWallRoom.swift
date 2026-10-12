import CoreGraphics
import Foundation
import SceneKit

/// The room the wall is in: a sofa, a low table, a lamp and a plant, standing
/// on the floor between the viewer and the wall.
///
/// None of it is interactive and all of it is in near-darkness — it exists so
/// the wall is a wall in a room rather than a strip of cards in a void, and so
/// the floor has something to reflect besides the wall itself. Built from
/// primitives: at this light level a box with a soft edge is a sofa.
enum LiveWallRoom {
    static func build(floorY: Float, palette: LiveWallPalette) -> SCNNode {
        let root = SCNNode()
        root.name = "room"

        root.addChildNode(sofa(floorY: floorY))
        root.addChildNode(table(floorY: floorY))
        root.addChildNode(lamp(floorY: floorY))
        root.addChildNode(plant(floorY: floorY))
        root.addChildNode(wallGlow())

        for node in root.childNodes {
            node.enumerateHierarchy { child, _ in
                child.categoryBitMask = LiveWallCardNode.decorationCategory
            }
        }
        return root
    }

    // MARK: - Pieces

    /// A low sofa at the viewer's left, seen from behind. It is built to be a
    /// silhouette: one soft-edged mass for the seat, one for the back, nothing
    /// that reads as a separate block. At this light level the outline is the
    /// whole of what says "sofa" — cushions and arms only ever read as boxes.
    private static func sofa(floorY: Float) -> SCNNode {
        let node = SCNNode()
        let fabric = material(
            color: CGColor(srgbRed: 0.030, green: 0.031, blue: 0.040, alpha: 1), roughness: 0.99)

        let seat = SCNBox(width: 2.3, height: 0.46, length: 1.05, chamferRadius: 0.20)
        seat.chamferSegmentCount = 6
        seat.materials = [fabric]
        let seatNode = SCNNode(geometry: seat)
        seatNode.simdPosition = SIMD3<Float>(0, 0.23, 0)
        node.addChildNode(seatNode)

        let back = SCNBox(width: 2.3, height: 0.50, length: 0.34, chamferRadius: 0.16)
        back.chamferSegmentCount = 6
        back.materials = [fabric]
        let backNode = SCNNode(geometry: back)
        backNode.simdPosition = SIMD3<Float>(0, 0.46 + 0.22, 0.36)
        // Leant back a little, the way a sofa back is.
        backNode.simdOrientation = simd_quatf(angle: 0.12, axis: SIMD3<Float>(1, 0, 0))
        node.addChildNode(backNode)

        node.simdPosition = SIMD3<Float>(-3.55, floorY, -4.60)
        node.simdOrientation = simd_quatf(angle: 0.12, axis: SIMD3<Float>(0, 1, 0))
        return node
    }

    /// A round coffee table at the viewer's right. Far enough back that its
    /// foot is in frame — a top with no visible base is a disc hanging in the
    /// air — with one tall thin bottle on it for a vertical.
    private static func table(floorY: Float) -> SCNNode {
        let node = SCNNode()
        let dark = material(
            color: CGColor(srgbRed: 0.040, green: 0.038, blue: 0.040, alpha: 1),
            roughness: 0.30, metalness: 0.15)

        let height: Float = 0.44
        let top = SCNCylinder(radius: 0.62, height: 0.035)
        top.materials = [dark]
        let topNode = SCNNode(geometry: top)
        topNode.simdPosition = SIMD3<Float>(0, height, 0)
        node.addChildNode(topNode)

        let column = SCNCylinder(radius: 0.05, height: CGFloat(height))
        column.materials = [dark]
        let columnNode = SCNNode(geometry: column)
        columnNode.simdPosition = SIMD3<Float>(0, height / 2, 0)
        node.addChildNode(columnNode)

        let foot = SCNCylinder(radius: 0.40, height: 0.03)
        foot.materials = [dark]
        let footNode = SCNNode(geometry: foot)
        footNode.simdPosition = SIMD3<Float>(0, 0.015, 0)
        node.addChildNode(footNode)

        let glass = material(
            color: CGColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.7),
            roughness: 0.12, metalness: 0.0)
        glass.transparency = 0.7
        let bottle = SCNCylinder(radius: 0.045, height: 0.36)
        bottle.materials = [glass]
        let bottleNode = SCNNode(geometry: bottle)
        bottleNode.simdPosition = SIMD3<Float>(0.14, height + 0.018 + 0.18, -0.08)
        node.addChildNode(bottleNode)

        node.simdPosition = SIMD3<Float>(1.95, floorY, -5.05)
        return node
    }

    /// A globe lamp on the floor by the sofa. The one warm thing in the room,
    /// and the only light in it that is not the wall.
    private static func lamp(floorY: Float) -> SCNNode {
        let node = SCNNode()

        let globe = SCNSphere(radius: 0.21)
        globe.segmentCount = 40
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = CGColor(srgbRed: 0.98, green: 0.74, blue: 0.48, alpha: 1)
        glow.emission.contents = CGColor(srgbRed: 0.95, green: 0.62, blue: 0.34, alpha: 1)
        glow.emission.intensity = 0.9
        globe.materials = [glow]
        let globeNode = SCNNode(geometry: globe)
        globeNode.simdPosition = SIMD3<Float>(0, 0.21, 0)
        node.addChildNode(globeNode)

        let halo = SCNPlane(width: 1.15, height: 1.15)
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        haloMaterial.readsFromDepthBuffer = false
        haloMaterial.diffuse.contents = radialGlow(
            color: CGColor(srgbRed: 1.0, green: 0.66, blue: 0.36, alpha: 1))
        halo.firstMaterial = haloMaterial
        let haloNode = SCNNode(geometry: halo)
        haloNode.simdPosition = SIMD3<Float>(0, 0.21, 0)
        haloNode.constraints = [SCNBillboardConstraint()]
        haloNode.renderingOrder = 30
        haloNode.opacity = 0.34
        node.addChildNode(haloNode)

        let light = SCNLight()
        light.type = .omni
        light.color = CGColor(srgbRed: 1.0, green: 0.72, blue: 0.45, alpha: 1)
        light.intensity = 90
        light.attenuationStartDistance = 0.2
        light.attenuationEndDistance = 1.2
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.simdPosition = SIMD3<Float>(0, 0.24, 0)
        node.addChildNode(lightNode)

        node.simdPosition = SIMD3<Float>(-2.05, floorY, -4.90)
        return node
    }

    /// A plant at the far right: a pot and a handful of broad leaves.
    private static func plant(floorY: Float) -> SCNNode {
        let node = SCNNode()

        let pot = SCNCylinder(radius: 0.24, height: 0.40)
        pot.materials = [material(
            color: CGColor(srgbRed: 0.135, green: 0.115, blue: 0.105, alpha: 1), roughness: 0.85)]
        let potNode = SCNNode(geometry: pot)
        potNode.simdPosition = SIMD3<Float>(0, 0.20, 0)
        node.addChildNode(potNode)

        let leafMaterial = material(
            color: CGColor(srgbRed: 0.095, green: 0.215, blue: 0.125, alpha: 1), roughness: 0.78)
        for index in 0..<7 {
            let leaf = SCNSphere(radius: 0.46)
            leaf.segmentCount = 20
            leaf.materials = [leafMaterial]
            let leafNode = SCNNode(geometry: leaf)
            let angle = Float(index) / 7 * 2 * .pi
            let lean: Float = 0.55 + Float(index % 3) * 0.12
            leafNode.simdScale = SIMD3<Float>(1.0, 0.22, 0.58)
            leafNode.simdPosition = SIMD3<Float>(
                cos(angle) * 0.42, 0.40 + 0.55 + Float(index % 2) * 0.28, sin(angle) * 0.42)
            leafNode.simdOrientation =
                simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -lean, axis: SIMD3<Float>(0, 0, 1))
            node.addChildNode(leafNode)
        }

        node.simdPosition = SIMD3<Float>(4.25, floorY, -3.85)
        return node
    }

    /// The wall's own light, standing in for it. Emissive cards do not light
    /// anything in SceneKit, so a cool lamp near the wall gives the furniture
    /// the blue rim it would have from a wall of televisions.
    private static func wallGlow() -> SCNNode {
        let light = SCNLight()
        light.type = .omni
        light.color = CGColor(srgbRed: 0.50, green: 0.63, blue: 0.95, alpha: 1)
        light.intensity = 95
        light.attenuationStartDistance = 1.0
        light.attenuationEndDistance = 6.5
        let node = SCNNode()
        node.light = light
        node.simdPosition = SIMD3<Float>(0, -0.7, -5.0)
        return node
    }

    /// A soft disc of light for the lamp's halo: opaque at the centre, gone
    /// well before the edge of the sprite so it never shows a square.
    private static func radialGlow(color: CGColor, side: Int = 256) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                color.copy(alpha: 0.85) ?? color,
                color.copy(alpha: 0.30) ?? color,
                color.copy(alpha: 0.06) ?? color,
                color.copy(alpha: 0) ?? color,
            ] as CFArray,
            locations: [0, 0.22, 0.55, 1])
        else { return nil }
        let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }

    // MARK: - Materials

    private static func material(
        color: CGColor, roughness: CGFloat, metalness: CGFloat = 0
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }
}
