#if os(tvOS)
import SceneKit
import SwiftUI

struct VoyageSceneView: UIViewRepresentable {
    let items: [BaseItem]
    let index: Int
    let client: JellyfinClient?
    let reduceMotion: Bool
    let focused: Bool

    func makeCoordinator() -> VoyageScene { VoyageScene() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(items: items, index: index, client: client,
                                   reduceMotion: reduceMotion, focused: focused)
    }
    static func dismantleUIView(_ view: SCNView, coordinator: VoyageScene) {
        coordinator.cancelImages()
        view.scene = nil
    }
}

/// Seven islands at most. Artwork jobs are cancelled as islands leave the horizon.
@MainActor
final class VoyageScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private var islands: [String: SCNNode] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var lastID: String?
    private let ocean = UIColor(red: 0.035, green: 0.10, blue: 0.17, alpha: 1)
    private let copper = UIColor(red: 0.94, green: 0.64, blue: 0.42, alpha: 1)

    init() {
        scene.background.contents = sky()
        scene.fogColor = ocean
        scene.fogStartDistance = 35
        scene.fogEndDistance = 105
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 51
        camera.camera?.zFar = 200
        camera.position = SCNVector3(0, 1.6, 18)
        camera.eulerAngles.x = -0.035
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(red: 0.48, green: 0.68, blue: 0.80, alpha: 1)
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.color = copper
        sun.light?.intensity = 1100
        sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
        scene.rootNode.addChildNode(sun)

        let water = SCNFloor()
        water.reflectivity = 0.22
        water.reflectionResolutionScaleFactor = 0.5
        water.firstMaterial?.diffuse.contents = UIColor(red: 0.065, green: 0.23, blue: 0.29, alpha: 1)
        water.firstMaterial?.roughness.contents = 0.3
        scene.rootNode.addChildNode(SCNNode(geometry: water))
        // Long, sparse wave crests give the ocean scale without perpetual motion.
        for i in 0..<42 {
            let wave = SCNBox(width: CGFloat(9 + i % 7 * 4), height: 0.015, length: 0.025, chamferRadius: 0)
            wave.firstMaterial?.diffuse.contents = UIColor(red: 0.27, green: 0.48, blue: 0.52, alpha: 0.35)
            let node = SCNNode(geometry: wave)
            node.position = SCNVector3(Float((i * 17) % 71 - 35), 0.025, Float(12 - i * 2))
            scene.rootNode.addChildNode(node)
        }
        // Distant basalt stacks, entirely procedural and fixed on the horizon.
        for i in 0..<19 {
            let rock = SCNCone(topRadius: 1.2, bottomRadius: CGFloat(3 + i % 4), height: CGFloat(4 + i % 5))
            rock.radialSegmentCount = 5
            rock.firstMaterial?.diffuse.contents = ocean
            let node = SCNNode(geometry: rock)
            node.position = SCNVector3(Float(i * 11 - 99), 1, Float(-50 - i % 3 * 8))
            scene.rootNode.addChildNode(node)
        }
    }

    func cancelImages() { jobs.values.forEach { $0.cancel() }; jobs.removeAll() }

    func update(items: [BaseItem], index: Int, client: JellyfinClient?, reduceMotion: Bool, focused: Bool) {
        guard items.indices.contains(index) else { return }
        let range = max(0, index - 3)...min(items.count - 1, index + 3)
        let visible = Set(range.map { items[$0].id })
        for id in Array(islands.keys) where !visible.contains(id) {
            islands.removeValue(forKey: id)?.removeFromParentNode()
            jobs.removeValue(forKey: id)?.cancel()
        }
        for i in range where islands[items[i].id] == nil {
            let item = items[i]
            let island = makeIsland(item: item)
            islands[item.id] = island
            scene.rootNode.addChildNode(island)
            let offset = Float(i - index)
            island.position = SCNVector3(offset * 12, 0, -abs(offset) * 6)
            let url = client?.imageURL(itemId: item.id, tag: item.imageTags?["Primary"], maxWidth: 700)
            if let url {
                jobs[item.id] = Task { [weak self, weak island] in
                    guard let image = try? await ImageLoader.shared.load(url), !Task.isCancelled,
                          let self, self.islands[item.id] === island else { return }
                    island?.childNode(withName: "poster", recursively: true)?.geometry?.firstMaterial?.diffuse.contents = image
                    self.jobs[item.id] = nil
                }
            }
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion || lastID == nil ? 0 : 0.48
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for i in range {
            let offset = Float(i - index)
            guard let island = islands[items[i].id] else { continue }
            island.position = SCNVector3(offset * 12, 0, -abs(offset) * 6)
            island.eulerAngles.y = offset == 0 ? 0 : (offset < 0 ? 0.18 : -0.18)
            island.childNode(withName: "halo", recursively: true)?.opacity = i == index && focused ? 1 : 0.22
        }
        SCNTransaction.commit()
        lastID = items[index].id
    }

    private func makeIsland(item: BaseItem) -> SCNNode {
        let root = SCNNode()
        let stone = SCNCylinder(radius: 4.3, height: 1.2)
        stone.radialSegmentCount = 7
        stone.firstMaterial?.diffuse.contents = UIColor(red: 0.16, green: 0.24, blue: 0.27, alpha: 1)
        let base = SCNNode(geometry: stone)
        base.position.y = 0.35
        root.addChildNode(base)
        let halo = SCNTorus(ringRadius: 4.4, pipeRadius: 0.035)
        halo.firstMaterial?.diffuse.contents = copper
        halo.firstMaterial?.emission.contents = copper
        let ring = SCNNode(geometry: halo)
        ring.name = "halo"
        ring.position.y = 0.97
        root.addChildNode(ring)
        let frame = SCNBox(width: 5.35, height: 7.85, length: 0.24, chamferRadius: 0.08)
        frame.firstMaterial?.diffuse.contents = copper
        let screen = SCNNode(geometry: frame)
        screen.position = SCNVector3(0, 5.1, 0)
        root.addChildNode(screen)
        let plane = SCNPlane(width: 5.1, height: 7.6)
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.diffuse.contents = placeholder(item.displayTitle)
        let poster = SCNNode(geometry: plane)
        poster.name = "poster"
        poster.position = SCNVector3(0, 5.1, 0.14)
        root.addChildNode(poster)
        return root
    }

    private func placeholder(_ title: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 510, height: 760)).image { context in
            ocean.setFill(); context.fill(CGRect(x: 0, y: 0, width: 510, height: 760))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: CGRect(x: 35, y: 310, width: 440, height: 360), withAttributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph])
        }
    }

    private func sky() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 1024)).image { context in
            let colors = [ocean.cgColor, UIColor(red: 0.20, green: 0.34, blue: 0.43, alpha: 1).cgColor,
                          UIColor(red: 0.72, green: 0.49, blue: 0.39, alpha: 1).cgColor, ocean.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.44, 0.66, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
        }
    }
}
#endif
