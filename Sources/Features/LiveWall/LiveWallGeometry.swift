import Foundation
import SceneKit

// Custom geometry for the parts of the room that have to follow the wall's
// curve. SceneKit's primitives are all flat or fully round; a band of the wall
// is neither, so it is built here as a strip of quads swept along the arc.

enum LiveWallGeometry {
    /// A curved strip lying on the cylinder: `segments` quads swept from
    /// `startAngle` to `endAngle`, `height` tall, centred on `centreY`, facing
    /// inward toward the axis. UVs run 0…1 across the sweep and up the strip,
    /// so a texture drawn to fade at its ends fades at the ends of the arc.
    static func band(
        radius: Float,
        startAngle: Float,
        endAngle: Float,
        height: Float,
        centreY: Float = 0,
        flatness: Float = 0,
        segments: Int = 96
    ) -> SCNGeometry {
        let count = max(2, segments)
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [Int32] = []

        let bottom = centreY - height / 2
        let top = centreY + height / 2

        for step in 0...count {
            let t = Float(step) / Float(count)
            let angle = startAngle + (endAngle - startAngle) * t
            // Same blend the cards use, so the line lies on the wall they are
            // on rather than on the circle they came from.
            let f = min(max(flatness, 0), 1)
            let x = radius * sin(angle) + (radius * angle - radius * sin(angle)) * f
            let z = -radius * cos(angle) + (-radius + radius * cos(angle)) * f
            let yaw = -angle * (1 - f)
            let normal = SCNVector3(-sin(yaw), 0, cos(yaw))

            vertices.append(SCNVector3(x, bottom, z))
            vertices.append(SCNVector3(x, top, z))
            normals.append(normal)
            normals.append(normal)
            uvs.append(CGPoint(x: CGFloat(t), y: 1))
            uvs.append(CGPoint(x: CGFloat(t), y: 0))
        }

        for step in 0..<count {
            let base = Int32(step * 2)
            indices.append(contentsOf: [base, base + 1, base + 2])
            indices.append(contentsOf: [base + 2, base + 1, base + 3])
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [
                SCNGeometryElement(indices: indices, primitiveType: .triangles),
            ])
        return geometry
    }

    /// A plane that hangs on the wall at a given angle, already turned to face
    /// the axis. Used for anything card-shaped that does not move.
    static func facingPlane(width: Float, height: Float) -> SCNPlane {
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        plane.cornerRadius = 0
        plane.widthSegmentCount = 1
        plane.heightSegmentCount = 1
        return plane
    }

    /// Material for anything that is its own light source — a screen, a light
    /// line, a bloom. Constant shading means the room's lamps cannot dim it and
    /// the texture arrives on screen as it was drawn.
    static func emissiveMaterial(blend: SCNBlendMode = .alpha) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = blend
        material.isDoubleSided = false
        material.writesToDepthBuffer = blend == .alpha
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        return material
    }
}
