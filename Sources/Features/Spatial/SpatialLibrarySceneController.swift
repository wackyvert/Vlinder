import Foundation
import SceneKit
#if os(macOS)
import AppKit
#endif

/// Owns the Atrium shelf: the camera, the shelf furniture, the mounted window of
/// cases, sifting along the arc, and pulling a case out to read its jacket.
///
/// Input arrives as abstract commands so the controller stays independent of
/// AppKit/UIKit event types, and cover URLs come from an injected closure so it
/// never touches Jellyfin networking directly.
@MainActor
final class SpatialLibrarySceneController: NSObject {
    enum Command {
        case previous, next, activate, escape, play
    }

    struct ArtworkSource {
        var cover: (BaseItem, Int) -> URL?
    }

    let scene = SCNScene()
    let layout: SpatialLibraryLayout
    weak var view: SCNView?

    var onSelectionChange: ((BaseItem?) -> Void)?
    var onOpenItem: ((BaseItem) -> Void)?
    var onPlayItem: ((BaseItem) -> Void)?
    /// Escape with nothing in hand: the shelf itself is what gets put away.
    var onBack: (() -> Void)?
    var onNeedsNextPage: (() -> Void)?

    var reduceMotion = false

    private(set) var items: [BaseItem] = []
    private var totalCount: Int?
    private var palette = AtriumPalette.palette(dark: true)
    private var artwork: ArtworkSource?

    private let cameraNode = SCNNode()
    private let shelfRoot = SCNNode()
    private let casesRoot = SCNNode()
    private let keyLight = SCNNode()
    private let fillLight = SCNNode()
    private let washLight = SCNNode()
    private let presentLight = SCNNode()

    private var mounted: [Int: SpatialCaseNode] = [:]
    private var nodePool: [SpatialCaseNode] = []
    private var nodeTasks: [ObjectIdentifier: [Task<Void, Never>]] = [:]

    /// Fractional position along the shelf. 3.0 means the fourth case is centred.
    private(set) var focus: Float = 0
    private(set) var selectedIndex: Int?

    /// The case currently centred — what a shelf remembers while the viewer is
    /// away inside a show.
    var focusedIndex: Int { items.isEmpty ? 0 : Int(focus.rounded()) }

    init(layout: SpatialLibraryLayout = SpatialLibraryLayout()) {
        self.layout = layout
        super.init()
        buildScene()
    }

    // MARK: - Scene

    private func buildScene() {
        let camera = SCNCamera()
        camera.fieldOfView = 52
        camera.zNear = 0.05
        camera.zFar = 60
        // A rendered look rather than flat paint: HDR with a little bloom on the
        // strip light, screen-space occlusion for contact shadow where the cases
        // meet the board, and just enough defocus to separate the row from the
        // case in hand. Exposure adaptation stays off so nothing drifts while idle.
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.34
        camera.whitePoint = 1.05
        camera.contrast = 0.10
        camera.saturation = 1.02
        camera.bloomIntensity = 0.14
        camera.bloomThreshold = 0.93
        camera.bloomBlurRadius = 11
        camera.screenSpaceAmbientOcclusionIntensity = 1.1
        camera.screenSpaceAmbientOcclusionRadius = 0.30
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.wantsDepthOfField = true
        camera.fStop = 9
        camera.focusDistance = CGFloat(layout.metrics.focusDistance)
        camera.apertureBladeCount = 6
        cameraNode.camera = camera
        cameraNode.simdPosition = layout.cameraPosition
        cameraNode.simdEulerAngles = SIMD3<Float>(
            layout.metrics.cameraPitchDegrees * .pi / 180, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(shelfRoot)
        scene.rootNode.addChildNode(casesRoot)

        // Two lights only: a soft ambient so shell stock and timber read, and a
        // key from above-front so the cases cast a little shadowless relief.
        // With image-based lighting doing the ambient work, the ambient light is
        // only a floor so nothing goes fully black.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 120
        fillLight.light = ambient
        scene.rootNode.addChildNode(fillLight)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 400
        key.temperature = 5600
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 9
        key.shadowSampleCount = 24
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
        key.orthographicScale = 4.5
        key.zNear = 0.1
        key.zFar = 24
        keyLight.light = key
        keyLight.simdPosition = SIMD3<Float>(1.4, 4.2, 3.4)
        keyLight.simdEulerAngles = SIMD3<Float>(-0.82, 0.26, 0)
        scene.rootNode.addChildNode(keyLight)

        // Warm wash from the strip under the shelf above, so the row is lit from
        // where the light visibly is.
        let wash = SCNLight()
        wash.type = .omni
        wash.intensity = 120
        wash.temperature = 3400
        wash.attenuationStartDistance = 0.8
        wash.attenuationEndDistance = 7.5
        washLight.light = wash
        washLight.simdPosition = SIMD3<Float>(
            0, layout.metrics.upperBoardY - 0.12, layout.metrics.caseWidth / 2 + 0.15)
        scene.rootNode.addChildNode(washLight)

        // Two more along the run, so the strip lights the whole shelf instead of
        // a single hot pool at the centre with dark ends.
        for side in [Float(-1), Float(1)] {
            let spread = SCNLight()
            spread.type = .omni
            spread.intensity = 85
            spread.temperature = 3400
            spread.attenuationStartDistance = 0.8
            spread.attenuationEndDistance = 6.5
            let node = SCNNode()
            node.light = spread
            let along = layout.position(atOffset: side * 11)
            node.simdPosition = SIMD3<Float>(
                along.x,
                layout.metrics.upperBoardY - 0.12,
                along.z + layout.metrics.caseWidth / 2 + 0.15)
            scene.rootNode.addChildNode(node)
        }

        // Lights the case in hand. Off while everything is racked.
        let present = SCNLight()
        present.type = .omni
        present.intensity = 0
        present.temperature = 5200
        present.attenuationStartDistance = 0.3
        present.attenuationEndDistance = 3.2
        presentLight.light = present
        scene.rootNode.addChildNode(presentLight)

        buildShelfFurniture()
        applyEnvironment()
    }

    /// The shelf is a strip of short segments stepped around the arc — cheaper
    /// and steadier than a lathed curve, and the joints are invisible at this
    /// radius. One board under the cases, one riser behind them.
    private func buildShelfFurniture() {
        let m = layout.metrics
        let span = m.mountedRadius + 4
        let segmentAngle = m.angularStep
        let segmentWidth = CGFloat(m.casePitch * 1.04)

        for offset in -span...span {
            let centre = layout.position(atOffset: Float(offset))

            let board = SCNNode(geometry: SCNBox(
                width: segmentWidth,
                height: CGFloat(m.shelfBoardThickness),
                length: CGFloat(m.shelfBoardDepth),
                chamferRadius: 0.004))
            board.geometry?.materials = [
                Self.material(palette.shelfEdge, roughness: 0.66),
                Self.material(palette.shelfEdge, roughness: 0.66),
                Self.material(palette.shelfEdge, roughness: 0.66),
                Self.material(palette.shelfEdge, roughness: 0.66),
                Self.material(palette.shelfBoard, roughness: 0.58),
                Self.material(palette.shelfEdge, roughness: 0.66),
            ]
            board.simdPosition = SIMD3<Float>(
                centre.x,
                m.shelfSurfaceY - m.shelfBoardThickness / 2,
                centre.z + m.shelfBoardDepth / 2 - m.caseThickness)
            board.simdOrientation = simd_quatf(
                angle: Float(offset) * segmentAngle, axis: SIMD3<Float>(0, 1, 0))
            board.categoryBitMask = SpatialCaseNode.decorationCategory
            shelfRoot.addChildNode(board)

            // The shelf above, closing the compartment over the row — the thing
            // that makes a bookcase read as a bookcase rather than a table.
            let upper = SCNNode(geometry: SCNBox(
                width: segmentWidth,
                height: CGFloat(m.shelfBoardThickness),
                length: CGFloat(m.shelfBoardDepth),
                chamferRadius: 0.004))
            upper.geometry?.materials = [
                Self.material(palette.shelfEdge), Self.material(palette.shelfEdge),
                Self.material(palette.shelfEdge), Self.material(palette.shelfEdge),
                Self.material(palette.shelfEdge), Self.material(palette.shelfBoard),
            ]
            upper.simdPosition = SIMD3<Float>(
                centre.x,
                m.upperBoardY + m.shelfBoardThickness / 2,
                centre.z + m.shelfBoardDepth / 2 - m.caseThickness)
            upper.simdOrientation = simd_quatf(
                angle: Float(offset) * segmentAngle, axis: SIMD3<Float>(0, 1, 0))
            upper.categoryBitMask = SpatialCaseNode.decorationCategory
            shelfRoot.addChildNode(upper)

            // Warm strip tucked under the shelf above, washing the row below.
            let strip = SCNNode(geometry: SCNBox(
                width: segmentWidth, height: 0.035, length: 0.06, chamferRadius: 0))
            let stripMaterial = SCNMaterial()
            stripMaterial.lightingModel = .constant
            stripMaterial.diffuse.contents = palette.shelfLight
            // Emissive so the camera's bloom pass sees it as a light source,
            // but well under the bloom threshold's full blast.
            stripMaterial.emission.contents = palette.shelfLight.copy(alpha: 0.62)
                ?? palette.shelfLight
            strip.geometry?.firstMaterial = stripMaterial
            strip.simdPosition = SIMD3<Float>(
                centre.x,
                m.upperBoardY - 0.02,
                centre.z + m.shelfBoardDepth / 2 - m.caseThickness - 0.06)
            strip.simdOrientation = simd_quatf(
                angle: Float(offset) * segmentAngle, axis: SIMD3<Float>(0, 1, 0))
            strip.categoryBitMask = SpatialCaseNode.decorationCategory
            strip.name = "shelfLight"
            shelfRoot.addChildNode(strip)

            let riser = SCNNode(geometry: SCNBox(
                width: segmentWidth,
                height: CGFloat(m.backPanelTopY - m.backPanelBottomY),
                length: 0.10,
                chamferRadius: 0))
            riser.geometry?.firstMaterial = Self.material(palette.backPanel, roughness: 0.88)
            riser.simdPosition = SIMD3<Float>(
                centre.x,
                (m.backPanelTopY + m.backPanelBottomY) / 2,
                centre.z - m.backPanelInset)
            riser.simdOrientation = board.simdOrientation
            riser.categoryBitMask = SpatialCaseNode.decorationCategory
            shelfRoot.addChildNode(riser)
        }
    }

    /// Physically based furniture material: timber and painted board want some
    /// roughness and no metalness, which is what gives them a lit surface rather
    /// than a flat fill.
    private static func material(_ color: CGColor, roughness: CGFloat = 0.72) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        return material
    }

    private func applyEnvironment() {
        if let gradient = SpatialTextures.verticalGradient(
            top: palette.backgroundTop, bottom: palette.backgroundBottom) {
            scene.background.contents = gradient
        } else {
            scene.background.contents = palette.backgroundBottom
        }
        // What the physically based materials reflect.
        scene.lightingEnvironment.contents = SpatialTextures.environmentMap(palette: palette)
        scene.lightingEnvironment.intensity = palette.isDark ? 0.72 : 1.30
        // Fog closes the shelf off at the ends so the run reads as continuing
        // rather than stopping at the last mounted case.
        scene.fogStartDistance = 6.5
        scene.fogEndDistance = 13.0
        scene.fogDensityExponent = 1.4
        scene.fogColor = palette.backgroundBottom

        for node in shelfRoot.childNodes {
            guard let materials = node.geometry?.materials else { continue }
            if node.name == "shelfLight" {
                materials.first?.diffuse.contents = palette.shelfLight
                materials.first?.emission.contents =
                    palette.shelfLight.copy(alpha: 0.62) ?? palette.shelfLight
                continue
            }
            guard materials.count == 6 else {
                materials.first?.diffuse.contents = palette.backPanel
                continue
            }
            // Boards show their lit face to the viewer: the top for the shelf
            // the cases stand on, the underside for the shelf above them.
            let litFace = node.simdPosition.y > 1 ? 5 : 4
            for (index, material) in materials.enumerated() {
                material.diffuse.contents = index == litFace ? palette.shelfBoard : palette.shelfEdge
            }
        }
    }

    // MARK: - Content

    func update(items newItems: [BaseItem], totalCount: Int?, reset: Bool) {
        let previousSelectionId = selectedIndex.flatMap {
            $0 < items.count ? items[$0].id : nil
        }
        items = newItems
        self.totalCount = totalCount

        if reset {
            unmountAll()
            focus = 0
            applyFocus(animated: false)
            if let previousSelectionId,
               let index = items.firstIndex(where: { $0.id == previousSelectionId }) {
                selectedIndex = nil
                setSelection(index)
            } else {
                setSelection(nil)
            }
        }
        remount()
        maybeRequestNextPage()
    }

    func setAppearance(dark: Bool) {
        let next = AtriumPalette.palette(dark: dark)
        guard next != palette else { return }
        palette = next
        SpatialTextures.flushCache()
        applyEnvironment()
        unmountAll()
        remount()
    }

    func setArtworkSource(_ source: ArtworkSource) {
        artwork = source
    }

    /// The field of view is set for a landscape frame. A portrait one — a phone
    /// held upright — would otherwise show a sliver of the shelf, so there the
    /// same angle is pinned across the width instead: the shelf keeps its
    /// familiar run, with more room above and below it.
    func adaptCamera(toViewSize size: CGSize) {
        guard size.width > 0, size.height > 0, let camera = cameraNode.camera else { return }
        let direction: SCNCameraProjectionDirection = size.height > size.width ? .horizontal : .vertical
        guard camera.projectionDirection != direction else { return }
        camera.projectionDirection = direction
    }

    // MARK: - Sifting

    /// Moves the focus along the shelf by a number of cases.
    func sift(by delta: Float) {
        guard !items.isEmpty else { return }
        let next = layout.clampedFocus(focus + delta, itemCount: items.count)
        guard next != focus else { return }
        focus = next
        applyFocus(animated: true)
        remount()
        maybeRequestNextPage()
    }

    /// Centres a specific case, gliding the shelf to it.
    func sift(toIndex index: Int, animated: Bool) {
        guard !items.isEmpty else { return }
        focus = layout.clampedFocus(Float(index), itemCount: items.count)
        applyFocus(animated: animated)
        remount()
        maybeRequestNextPage()
    }

    /// Lets a run that stopped between two cases come to rest on the nearer one.
    /// Touch needs it — a finger leaves the shelf wherever it lifts — where a
    /// scroll wheel's ticks already land where the layout puts them.
    func settle() {
        guard !items.isEmpty else { return }
        let target = layout.clampedFocus(focus.rounded(), itemCount: items.count)
        guard target != focus else { return }
        focus = target
        applyFocus(animated: true)
        remount()
        maybeRequestNextPage()
    }

    /// The shelf itself never moves; the cases are restood at their new angles.
    /// Animating their transforms is what makes the run appear to glide past.
    private func applyFocus(animated: Bool) {
        let m = layout.metrics
        SCNTransaction.begin()
        SCNTransaction.animationDuration = (animated && !reduceMotion) ? 0.22 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        for (index, node) in mounted {
            let slot = layout.slot(forItemIndex: index, focus: focus)
            node.place(slot: slot)
            node.setTilted(slot.tilt > 0.5 && selectedIndex == nil,
                           metrics: m, reduceMotion: reduceMotion || !animated)
        }
        if let selectedIndex, let node = mounted[selectedIndex] {
            node.flyOut(to: flyOutTransform(), reduceMotion: reduceMotion)
        }
        SCNTransaction.commit()
    }

    /// Cover art is only wanted where a case could be tipped out; the rest of
    /// the shelf is spines, which cost one small generated texture each.
    private func requestCoversNearFocus() {
        let centre = Int(focus.rounded())
        let radius = layout.metrics.coverRadius
        for index in (centre - radius)...(centre + radius) {
            guard index >= 0, index < items.count,
                  let node = mounted[index], !node.hasCover else { continue }
            requestCover(for: node, item: items[index], token: node.generation)
        }
    }

    private func maybeRequestNextPage() {
        if layout.shouldRequestNextPage(
            focus: focus, loadedItemCount: items.count, totalCount: totalCount) {
            onNeedsNextPage?()
        }
    }

    // MARK: - Mounting

    private func remount() {
        let window = layout.mountedRange(focus: focus, itemCount: items.count)
        for index in mounted.keys where !window.contains(index) {
            unmount(index)
        }
        for index in window where mounted[index] == nil {
            mount(index)
        }
        requestCoversNearFocus()
        refreshSelectionAppearance()
    }

    private func mount(_ index: Int) {
        guard index < items.count else { return }
        let node = dequeueNode()
        node.configure(metrics: layout.metrics, pivotOffset: layout.tiltPivotOffset)
        node.place(slot: layout.slot(forItemIndex: index, focus: focus))
        let token = node.assign(item: items[index], index: index, palette: palette)
        requestTextures(for: node, item: items[index], token: token)
        casesRoot.addChildNode(node)
        mounted[index] = node
    }

    private func unmount(_ index: Int) {
        guard let node = mounted.removeValue(forKey: index) else { return }
        cancelTasks(for: node)
        node.clear()
        node.removeFromParentNode()
        if nodePool.count < 32 {
            nodePool.append(node)
        }
    }

    private func unmountAll() {
        for index in Array(mounted.keys) {
            unmount(index)
        }
    }

    private func dequeueNode() -> SpatialCaseNode {
        nodePool.popLast() ?? SpatialCaseNode()
    }

    private func cancelTasks(for node: SpatialCaseNode) {
        let key = ObjectIdentifier(node)
        nodeTasks[key]?.forEach { $0.cancel() }
        nodeTasks[key] = nil
    }

    private func track(_ task: Task<Void, Never>, for node: SpatialCaseNode) {
        nodeTasks[ObjectIdentifier(node), default: []].append(task)
    }

    // MARK: - Textures

    private func requestTextures(for node: SpatialCaseNode, item: BaseItem, token: UUID) {
        cancelTasks(for: node)
        let palette = palette
        let casePrint = item.atriumPrint
        let title = casePrint.spineTitle
        let footnote = casePrint.spineFootnote
        let unplayed = item.userData?.unplayedItemCount ?? 0
        let played = item.userData?.played == true

        // Detached, not Task.init: this type is @MainActor and Task.init would
        // inherit that isolation, putting every rasterization on the main thread.
        let printTask = Task.detached(priority: .userInitiated) {
            let spine = SpatialTextures.spine(
                title: title, footnote: footnote, tint: nil, palette: palette)
            let badge: (CGImage, CGFloat)? = {
                if unplayed > 0, let image = SpatialTextures.countBadge(unplayed, palette: palette) {
                    return (image, CGFloat(image.width) / CGFloat(image.height))
                }
                if played, let image = SpatialTextures.watchedBadge(palette: palette) {
                    return (image, 1)
                }
                return nil
            }()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let spine { node.applySpine(spine, generation: token) }
                if let badge { node.applyBadge(badge.0, aspect: badge.1, generation: token) }
            }
        }
        track(printTask, for: node)

        // A thumbnail is enough to colour the spine, and cheap enough to fetch
        // for every case on the shelf — a real shelf is a run of colours, not
        // one uniform block.
        if let thumbURL = artwork?.cover(item, 48) {
            let tintTask = Task { [weak node] in
                guard let image = try? await ImageLoader.shared.load(thumbURL) else { return }
                guard !Task.isCancelled,
                      let source = SpatialTextures.sourceImage(for: thumbURL, from: image)
                else { return }
                let reprinted = await Task.detached(priority: .utility) {
                    guard let tint = SpatialTextures.spineTint(from: source) else { return nil as CGImage? }
                    return SpatialTextures.spine(
                        title: title, footnote: footnote, tint: tint, palette: palette)
                }.value
                guard !Task.isCancelled, let reprinted else { return }
                node?.applySpine(reprinted, generation: token)
            }
            track(tintTask, for: node)
        }
    }

    private func requestCover(for node: SpatialCaseNode, item: BaseItem, token: UUID) {
        let aspect = CGFloat(layout.metrics.caseWidth / layout.metrics.caseHeight)
        let casePrint = item.atriumPrint
        let palette = palette

        guard let url = artwork?.cover(item, 420) else {
            // An episode the server never made a still for still gets a jacket;
            // anything else simply keeps its shell.
            guard casePrint.jacket != .cover else { return }
            let printTask = Task { [weak node] in
                let printed = await Task.detached(priority: .userInitiated) {
                    Self.jacket(art: nil, print: casePrint, palette: palette, aspect: aspect)
                }.value
                guard !Task.isCancelled, let printed else { return }
                node?.applyCover(printed, generation: token)
            }
            track(printTask, for: node)
            return
        }

        let coverTask = Task { [weak node] in
            guard let image = try? await ImageLoader.shared.load(url) else { return }
            guard !Task.isCancelled else { return }
            guard let source = SpatialTextures.sourceImage(for: url, from: image) else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.jacket(art: source, print: casePrint, palette: palette, aspect: aspect)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            node?.applyCover(decoded, generation: token)
        }
        track(coverTask, for: node)
    }

    /// The case face: artwork alone where the item has a jacket of its own,
    /// something printed where it does not.
    private nonisolated static func jacket(
        art: CGImage?,
        print casePrint: AtriumCasePrint,
        palette: AtriumPalette,
        aspect: CGFloat
    ) -> CGImage? {
        switch casePrint.jacket {
        case .cover:
            guard let art else { return nil }
            return SpatialTextures.resampled(art, maxPixel: 780, aspect: aspect)
        case .still, .bandedPoster:
            return SpatialTextures.jacket(
                art: art,
                style: casePrint.jacket == .still ? .stillAbovePrint : .printedFoot,
                kicker: casePrint.bandKicker,
                title: casePrint.bandTitle ?? casePrint.spineTitle,
                palette: palette,
                aspect: aspect)
        }
    }

    // MARK: - Selection

    var selectedItem: BaseItem? {
        guard let selectedIndex, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    /// Where a pulled case floats: in front of the camera, turned so the cover
    /// and the spine both read at once.
    private func flyOutTransform() -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let m = layout.metrics
        let camera = layout.cameraPosition
        let position = SIMD3<Float>(
            camera.x + m.flyOutOffset.x,
            camera.y + m.flyOutOffset.y,
            camera.z + m.flyOutOffset.z)
        let yaw = simd_quatf(angle: m.flyOutYawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: m.flyOutPitchDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        return (position, yaw * pitch)
    }

    /// Focus and fill follow whatever the viewer is actually looking at: the row
    /// when everything is racked, the jacket once a case is in hand.
    private func focusCamera(onPresentedCase presented: Bool) {
        let m = layout.metrics
        let target = presented
            ? simd_distance(flyOutTransform().position, layout.cameraPosition)
            : m.focusDistance
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.44
        cameraNode.camera?.focusDistance = CGFloat(target)
        if presented {
            let transform = flyOutTransform()
            let toCamera = simd_normalize(layout.cameraPosition - transform.position)
            presentLight.simdPosition = transform.position + toCamera * 1.15
                + SIMD3<Float>(0.55, 0.75, 0)
        }
        presentLight.light?.intensity = presented ? 130 : 0
        SCNTransaction.commit()
    }

    func setSelection(_ index: Int?) {
        if let index {
            guard index >= 0, index < items.count else { return }
        }
        let previous = selectedIndex
        selectedIndex = index

        if let previous, previous != index, let node = mounted[previous] {
            node.returnToShelf(reduceMotion: reduceMotion)
        }
        if let index {
            // Bring the chosen case to the middle of the shelf before it comes
            // out, so it never flies in from off-screen.
            sift(toIndex: index, animated: true)
            mounted[index]?.flyOut(to: flyOutTransform(), reduceMotion: reduceMotion)
        }
        focusCamera(onPresentedCase: index != nil)
        refreshSelectionAppearance()
        onSelectionChange?(selectedItem)
    }

    private func refreshSelectionAppearance() {
        let hasSelection = selectedIndex != nil
        let m = layout.metrics
        for (index, node) in mounted {
            if index == selectedIndex {
                if !node.isFlownOut {
                    node.flyOut(to: flyOutTransform(), reduceMotion: reduceMotion)
                }
            } else {
                node.returnToShelf(reduceMotion: reduceMotion)
                node.setDimmed(hasSelection)
                // With a case in hand nothing else stands proud of the row.
                let slot = layout.slot(forItemIndex: index, focus: focus)
                node.setTilted(!hasSelection && slot.tilt > 0.5,
                               metrics: m, reduceMotion: reduceMotion)
            }
        }
    }

    // MARK: - Input

    func handle(_ command: Command) {
        switch command {
        case .escape:
            // With a case in hand, put it back; with an empty hand, put the
            // whole shelf back and return to the one above it.
            if selectedIndex != nil {
                setSelection(nil)
            } else {
                onBack?()
            }
        case .play:
            let index = selectedIndex ?? Int(focus.rounded())
            guard index >= 0, index < items.count else { return }
            onPlayItem?(items[index])
        case .activate:
            if let item = selectedItem {
                onOpenItem?(item)
            } else if !items.isEmpty {
                setSelection(Int(focus.rounded()))
            }
        case .previous, .next:
            let direction: SpatialNavDirection = command == .next ? .next : .previous
            // With nothing selected, the arrows sift the shelf. With a case in
            // hand, they put it back and pull out its neighbour.
            let anchor = selectedIndex ?? Int(focus.rounded())
            guard let next = layout.neighbourIndex(
                from: anchor, direction: direction, itemCount: items.count) else { return }
            if selectedIndex == nil {
                sift(toIndex: next, animated: true)
            } else {
                setSelection(next)
            }
        }
    }

    /// Hands key focus back to the scene after a tap on native chrome, so a
    /// keyboard keeps driving the shelf.
    func focusSceneView() {
        guard let view else { return }
        #if os(macOS)
        view.window?.makeFirstResponder(view)
        #else
        view.becomeFirstResponder()
        #endif
    }

    /// A click selects the case under the pointer; clicking the case already in
    /// hand puts it back on the shelf.
    func handleTap(at point: CGPoint) {
        guard let view else { return }
        let results = view.hitTest(point, options: [
            .categoryBitMask: SpatialCaseNode.hitTestCategory as NSNumber,
            .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber,
        ])
        var hit: SpatialCaseNode?
        for result in results {
            var candidate: SCNNode? = result.node
            while let current = candidate {
                if let caseNode = current as? SpatialCaseNode {
                    hit = caseNode
                    break
                }
                candidate = current.parent
            }
            if hit != nil { break }
        }
        guard let hit, hit.itemIndex >= 0 else {
            setSelection(nil)
            return
        }
        if hit.itemIndex == selectedIndex {
            setSelection(nil)
        } else {
            setSelection(hit.itemIndex)
        }
    }
}
