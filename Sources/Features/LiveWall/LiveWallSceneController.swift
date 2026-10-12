#if os(macOS)
import AppKit
#endif
import Foundation
import SceneKit

/// The Live TV Atrium: a wall of channels wrapped around the viewer, one band
/// per lineup group.
///
/// The room is almost entirely dark and almost entirely unlit — the cards are
/// the light. What the scene owns beyond them is the instrumentation: the light
/// line that separates one band from the next, the plate that names a band, the
/// thread that marks where "now" is, and a floor dark enough to hold their
/// reflection.
@MainActor
final class LiveWallSceneController: NSObject {
    enum Command {
        case left, right, up, down, play, escape
    }

    /// Where a card's picture comes from. The view owns the client; this owns
    /// only the shape of the ask.
    struct ArtworkSource {
        var still: (LiveWallCard, Int) -> URL?
    }

    let scene = SCNScene()
    let layout: LiveWallLayout

    weak var view: SCNView?

    var onSelectionChange: ((LiveWallCard?) -> Void)?
    var onPlay: ((LiveWallCard) -> Void)?
    var onEscape: (() -> Void)?

    var reduceMotion = false

    private(set) var bands: [LiveWallBand] = []
    private var palette = LiveWallPalette.palette(dark: true)
    private var artwork: ArtworkSource?

    private let cameraNode = SCNNode()
    private let wallRoot = SCNNode()
    private let cardsRoot = SCNNode()
    private let trimRoot = SCNNode()
    private let nowThread = SCNNode()
    private let nowLabel = SCNNode()
    private let floorNode = SCNNode()
    private let roomRoot = SCNNode()

    private var separators: [SCNNode] = []
    private var plates: [SCNNode] = []

    private var mounted: [CardKey: LiveWallCardNode] = [:]
    private var nodePool: [LiveWallCardNode] = []
    private var nodeTasks: [ObjectIdentifier: [Task<Void, Never>]] = [:]

    /// Which band the viewer is looking at, and where they were left in each
    /// band — a wall you can look away from and back to without losing your
    /// place.
    private var rowFocus: Float = 0
    private var columnFocus: [Float] = []
    /// Bands the viewer has actually been in. An unvisited band has no place of
    /// its own to return to, so it adopts the column being left behind.
    private var visitedRows: Set<Int> = []

    private var clockTimer: Timer?

    private struct CardKey: Hashable {
        let row: Int
        let column: Int
    }

    init(metrics: LiveWallMetrics = LiveWallMetrics()) {
        layout = LiveWallLayout(metrics: metrics)
        super.init()
        buildScene()
        // Synthesising the ticks and standing up their players costs a few
        // milliseconds; better spent here than on the first key press.
        _ = LiveWallSound.shared
    }

    deinit {
        clockTimer?.invalidate()
    }

    /// The eye, exposed so an offscreen renderer can shoot the same scene the
    /// window is showing.
    var pointOfView: SCNNode { cameraNode }

    var focusedRow: Int { bands.isEmpty ? 0 : min(max(Int(rowFocus.rounded()), 0), bands.count - 1) }

    var focusedColumn: Int {
        guard focusedRow < columnFocus.count else { return 0 }
        let count = bands[focusedRow].cards.count
        guard count > 0 else { return 0 }
        return min(max(Int(columnFocus[focusedRow].rounded()), 0), count - 1)
    }

    var focusedCard: LiveWallCard? {
        guard focusedRow < bands.count else { return nil }
        let cards = bands[focusedRow].cards
        guard focusedColumn < cards.count else { return nil }
        return cards[focusedColumn]
    }

    // MARK: - Building the room

    private func buildScene() {
        scene.rootNode.addChildNode(wallRoot)
        wallRoot.addChildNode(cardsRoot)
        wallRoot.addChildNode(trimRoot)

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(layout.metrics.fieldOfViewDegrees)
        camera.projectionDirection = .horizontal
        camera.zNear = 0.05
        camera.zFar = 200
        camera.wantsHDR = false
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        cameraNode.simdPosition = layout.cameraPosition
        cameraNode.simdOrientation = simd_quatf(
            angle: layout.metrics.cameraPitchDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(roomRoot)

        applyEnvironment()
        buildFloor()
        buildNowThread()
    }

    private func applyEnvironment() {
        scene.background.contents = LiveWallTextures.roomBackground(palette: palette)
        scene.background.wrapS = .clamp
        scene.background.wrapT = .clamp

        // One very soft ambient so the plates and the floor are not pure black;
        // everything that matters lights itself.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = CGColor(srgbRed: 0.16, green: 0.19, blue: 0.34, alpha: 1)
        ambient.intensity = 240
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    /// A dark, faintly polished floor. Its whole job is to catch the wall's
    /// reflection, which is most of what tells the eye this is a room.
    private func buildFloor() {
        let floor = SCNFloor()
        // A polished floor: the wall and the lamp show in it, softening with
        // distance, the way they would in a dark room with a hard floor.
        floor.reflectivity = 0.24
        floor.reflectionFalloffStart = 0.2
        floor.reflectionFalloffEnd = 3.0
        floor.reflectionResolutionScaleFactor = 0.3
        // Lambert, not PBR: the floor is the largest lit surface in the scene
        // and needs no specular of its own — the reflection is its shine.
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = CGColor(srgbRed: 0.016, green: 0.019, blue: 0.040, alpha: 1)
        floor.firstMaterial = material
        floorNode.geometry = floor
        floorNode.categoryBitMask = LiveWallCardNode.decorationCategory
        scene.rootNode.addChildNode(floorNode)
        positionFloor()
    }

    /// The floor sits just under the lowest band that can be reached, so the
    /// wall always has something to stand on however many bands there are.
    /// The floor does not move: the wall scrolls past it. Bands that fall
    /// below it are simply under the floor, which is where the room ends.
    private func positionFloor() {
        floorNode.simdPosition = SIMD3<Float>(0, layout.floorY, 0)
    }

    /// Stands the furniture once. It is in world space and never moves.
    private func furnishIfNeeded() {
        guard roomRoot.childNodes.isEmpty else { return }
        roomRoot.addChildNode(LiveWallRoom.build(floorY: layout.floorY, palette: palette))
    }

    /// The "now" thread: a hairline running up the wall through the card the
    /// viewer is on, with the clock at its head. It is the only thing in the
    /// room that reports a fact about time rather than about television.
    private func buildNowThread() {
        let thread = SCNPlane(width: 0.010, height: CGFloat(layout.metrics.rowPitch) * 1.70)
        let material = LiveWallGeometry.emissiveMaterial(blend: .add)
        material.diffuse.contents = CGColor(srgbRed: 0.62, green: 0.78, blue: 1, alpha: 0.5)
        thread.firstMaterial = material
        nowThread.geometry = thread
        nowThread.categoryBitMask = LiveWallCardNode.decorationCategory
        nowThread.opacity = 0.38
        wallRoot.addChildNode(nowThread)

        let label = SCNPlane(width: 0.62, height: 0.31)
        label.firstMaterial = LiveWallGeometry.emissiveMaterial(blend: .add)
        nowLabel.geometry = label
        nowLabel.categoryBitMask = LiveWallCardNode.decorationCategory
        wallRoot.addChildNode(nowLabel)

        refreshClock()
        // The clock is the one thing on the wall that has to be right without
        // anyone touching it.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func refreshClock() {
        let accent = palette.accent(focusedRow)
        let label = GuideTime.label(for: Date(), style: .exact)
        nowLabel.geometry?.firstMaterial?.diffuse.contents =
            LiveWallTextures.timeMarker(label: label, palette: palette, accent: accent)
    }

    // MARK: - Trim that depends on the bands

    /// Rebuilds the light lines and the band plates. Cheap enough to redo
    /// whenever the lineup changes, and there is no state in them worth keeping.
    private func rebuildTrim() {
        separators.forEach { $0.removeFromParentNode() }
        plates.forEach { $0.removeFromParentNode() }
        separators = []
        plates = []

        guard !bands.isEmpty else { return }
        let metrics = layout.metrics
        let halfSweep: Float = 0.78

        for index in bands.indices {
            let accent = palette.accent(bands[index].accentIndex)

            if index < bands.count - 1 {
                let geometry = LiveWallGeometry.band(
                    radius: metrics.radius - 0.01,
                    startAngle: -halfSweep, endAngle: halfSweep,
                    height: metrics.rowPitch * 0.20,
                    flatness: metrics.flatness)
                let material = LiveWallGeometry.emissiveMaterial(blend: .add)
                material.isDoubleSided = true
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.categoryBitMask = LiveWallCardNode.decorationCategory
                node.name = "separator-\(index)"
                trimRoot.addChildNode(node)
                separators.append(node)
            }

            let plate = SCNPlane(
                width: CGFloat(metrics.plateWidth), height: CGFloat(metrics.plateHeight))
            plate.cornerRadius = CGFloat(metrics.plateWidth) * 0.08
            let plateMaterial = LiveWallGeometry.emissiveMaterial()
            // The plate is foreground furniture, not part of the wall: it is
            // drawn last and does not consult the depth buffer, so a card that
            // happens to sit behind it can never show through.
            plateMaterial.readsFromDepthBuffer = false
            plate.firstMaterial = plateMaterial
            let plateNode = SCNNode(geometry: plate)
            plateNode.categoryBitMask = LiveWallCardNode.decorationCategory
            plateNode.name = "plate-\(index)"
            // Cards and plates are both alpha-blended, so depth alone will not
            // decide which wins where they overlap. The plate stands in front
            // of the wall, so it is drawn last and covers what is behind it.
            plateNode.renderingOrder = 20
            trimRoot.addChildNode(plateNode)
            plates.append(plateNode)
            _ = accent
        }

        refreshPlateArt()
    }

    /// A qualifier every band shares ("CABLE" on all of them) tells the bands
    /// apart from nothing, so it is dropped; one that varies is kept.
    private var kickersAreInformative: Bool {
        let kickers = Set(bands.map { $0.plateKicker ?? "" })
        return kickers.count > 1
    }

    private func refreshPlateArt() {
        // The qualifier reads as noise on a plate the size of a card: three of
        // four bands say the same word, and the word that matters is the other
        // one. What kind of television it is, the wall already says.
        let showKickers = false
        for (index, node) in plates.enumerated() where index < bands.count {
            let band = bands[index]
            let emphasis = index == focusedRow
            node.geometry?.firstMaterial?.diffuse.contents = LiveWallTextures.groupPlate(
                name: band.plateTitle,
                kicker: showKickers ? band.plateKicker : nil,
                symbolName: band.symbolName,
                accent: palette.accent(band.accentIndex),
                palette: palette,
                emphasis: emphasis)
        }
        for (index, node) in separators.enumerated() where index < bands.count {
            let emphasis = index == focusedRow || index + 1 == focusedRow
            node.geometry?.firstMaterial?.diffuse.contents = LiveWallTextures.separatorLine(
                accent: palette.accent(bands[index].accentIndex),
                emphasis: emphasis)
        }
    }

    // MARK: - Data

    func update(bands newBands: [LiveWallBand]) {
        let sameShape = newBands.count == bands.count
            && zip(newBands, bands).allSatisfy { $0.name == $1.name && $0.cards.count == $1.cards.count }

        bands = newBands
        if columnFocus.count != newBands.count {
            columnFocus = Array(repeating: 0, count: newBands.count)
            visitedRows = []
        }
        rowFocus = layout.clampedFocus(rowFocus, count: newBands.count)
        for index in columnFocus.indices {
            columnFocus[index] = layout.clampedFocus(columnFocus[index], count: newBands[index].cards.count)
        }

        if !sameShape {
            unmountAll()
            rebuildTrim()
        }
        positionFloor()
        furnishIfNeeded()
        applyFocus(animated: false)
        onSelectionChange?(focusedCard)
    }

    func setAppearance(dark: Bool) {
        guard dark != palette.isDark else { return }
        palette = .palette(dark: dark)
        LiveWallTextures.flushCache()
        applyEnvironment()
        floorNode.geometry?.firstMaterial?.diffuse.contents = palette.floor
        rebuildTrim()
        refreshClock()
        unmountAll()
        applyFocus(animated: false)
    }

    func setArtworkSource(_ source: ArtworkSource) {
        artwork = source
        unmountAll()
        applyFocus(animated: false)
    }

    // MARK: - Moving about

    /// The card under the eye, as a key into the mounted nodes.
    private var focusedKey: CardKey? {
        guard focusedRow < bands.count, !bands[focusedRow].cards.isEmpty else { return nil }
        return CardKey(row: focusedRow, column: focusedColumn)
    }

    /// Every change of focus goes through here: it remembers which card had
    /// the eye, makes the change, and then reprints only the two cards whose
    /// printing actually differs — the one that lost the focus and the one
    /// that took it. Everything else keeps the face it already has.
    private func moveFocus(animated: Bool, sound: LiveWallSound.Kind?, _ change: () -> Void) {
        let before = focusedKey
        change()
        let after = focusedKey
        applyFocus(animated: animated)
        if before != after {
            reprint([before, after].compactMap { $0 })
            if let sound { LiveWallSound.shared.play(sound) }
        }
        onSelectionChange?(focusedCard)
    }

    /// Trackpad scrolling along the current band. Each card the focus crosses
    /// gives one tick, so a flick sounds like the dial it is.
    func sift(by delta: Float) {
        guard focusedRow < bands.count else { return }
        let count = bands[focusedRow].cards.count
        guard count > 0 else { return }
        moveFocus(animated: false, sound: .step) {
            columnFocus[focusedRow] = layout.clampedFocus(
                columnFocus[focusedRow] + delta, count: count)
        }
    }

    /// Settles a scroll onto the nearest card, so the wall never rests between
    /// two of them.
    func settle() {
        guard focusedRow < columnFocus.count else { return }
        let target = columnFocus[focusedRow].rounded()
        guard target != columnFocus[focusedRow] else { return }
        moveFocus(animated: true, sound: nil) {
            columnFocus[focusedRow] = target
        }
    }

    func handle(_ command: Command) {
        switch command {
        case .left, .right:
            guard focusedRow < bands.count else { return }
            let count = bands[focusedRow].cards.count
            guard let next = layout.neighbour(
                from: focusedColumn, forward: command == .right, count: count) else { return }
            moveFocus(animated: true, sound: .step) {
                columnFocus[focusedRow] = Float(next)
            }

        case .up, .down:
            guard let next = layout.neighbour(
                from: focusedRow, forward: command == .down, count: bands.count) else { return }
            moveFocus(animated: true, sound: .band) {
                adopt(column: focusedColumn, into: next)
                rowFocus = Float(next)
                positionFloor()
                refreshPlateArt()
                refreshClock()
            }

        case .play:
            if let card = focusedCard { onPlay?(card) }

        case .escape:
            onEscape?()
        }
    }

    /// Seeds a band that has never been looked at with the column being left,
    /// so its run is already filled either side when it comes into view.
    private func adopt(column: Int, into row: Int) {
        guard row >= 0, row < bands.count, !visitedRows.contains(row) else { return }
        visitedRows.insert(row)
        columnFocus[row] = layout.clampedFocus(Float(column), count: bands[row].cards.count)
    }

    func focus(row: Int, column: Int, animated: Bool) {
        guard row >= 0, row < bands.count else { return }
        moveFocus(animated: animated, sound: nil) {
            rowFocus = Float(row)
            visitedRows.insert(row)
            columnFocus[row] = layout.clampedFocus(Float(column), count: bands[row].cards.count)
            // Everything else on screen should be filled to the same depth, so
            // the wall reads as a wall rather than as one row with stragglers.
            for other in bands.indices where other != row {
                adopt(column: column, into: other)
            }
            positionFloor()
            refreshPlateArt()
        }
    }

    // MARK: - Placement

    private func applyFocus(animated: Bool) {
        remount()

        let duration = animated && !reduceMotion ? 0.30 : 0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        placeEverything()
        SCNTransaction.commit()
    }

    private func placeEverything() {
        for (key, node) in mounted {
            node.place(slot: slot(for: key))
        }
        placeTrim()
    }

    private func slot(for key: CardKey) -> LiveWallSlot {
        layout.slot(
            row: key.row, column: key.column,
            rowFocus: rowFocus,
            columnFocus: columnFocus(for: key.row))
    }

    private func columnFocus(for row: Int) -> Float {
        row < columnFocus.count ? columnFocus[row] : 0
    }

    private func placeTrim() {
        let metrics = layout.metrics

        for (index, node) in separators.enumerated() {
            node.simdPosition = SIMD3<Float>(
                0, layout.separatorHeight(belowRow: index, rowFocus: rowFocus), 0)
            node.opacity = CGFloat(0.30 + 0.70 * smoothFalloff(abs(Float(index) + 0.5 - rowFocus), edge: 2.2))
        }

        for (index, node) in plates.enumerated() {
            let slot = layout.plateSlot(row: index, rowFocus: rowFocus)
            node.simdPosition = slot.position
            node.simdOrientation = simd_quatf(angle: slot.yawRadians, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: slot.pitchRadians, axis: SIMD3<Float>(1, 0, 0))
            // A plate is a solid pane and stays solid: fading one lets the wall
            // behind it show through its face. The band it is not on reads as
            // quieter through its printing, not through its opacity.
            node.opacity = 1
            // Plates draw over everything, floor included, so one that has
            // scrolled under the floor has to be taken out by hand.
            node.isHidden = slot.position.y + metrics.plateHeight / 2 < layout.floorY + 0.03
        }

        // The thread stands at the angle of the card being looked at, so it
        // slides along the wall as the viewer moves.
        let theta = layout.angle(atColumnOffset: 0)
        let focusAngleOffset = Float(focusedColumn) - columnFocus(for: focusedRow)
        let threadAngle = layout.angle(atColumnOffset: focusAngleOffset) - theta
        // The thread hangs above the focused band rather than through it, so
        // it never crosses the card it is pointing at, and it sits on the same
        // flattened wall as everything else.
        let point = layout.wallPoint(atAngle: threadAngle)
        let threadY = layout.height(atRowOffset: 0) + metrics.rowPitch * 0.95
        let orientation = simd_quatf(angle: point.yaw, axis: SIMD3<Float>(0, 1, 0))

        nowThread.simdPosition = SIMD3<Float>(point.position.x, threadY, point.position.y + 0.05)
        nowThread.simdOrientation = orientation
        nowLabel.simdPosition = SIMD3<Float>(
            point.position.x, threadY + metrics.rowPitch * 0.62, point.position.y + 0.05)
        nowLabel.simdOrientation = orientation
    }

    // MARK: - Mounting

    private func remount() {
        var wanted = Set<CardKey>()
        for row in layout.mountedRows(rowFocus: rowFocus, rowCount: bands.count) {
            let cards = bands[row].cards
            for column in layout.mountedColumns(
                columnFocus: columnFocus(for: row), columnCount: cards.count) {
                wanted.insert(CardKey(row: row, column: column))
            }
        }

        for key in mounted.keys where !wanted.contains(key) {
            unmount(key)
        }
        for key in wanted where mounted[key] == nil {
            mount(key)
        }
    }

    private func mount(_ key: CardKey) {
        guard key.row < bands.count else { return }
        let cards = bands[key.row].cards
        guard key.column < cards.count else { return }
        let card = cards[key.column]

        let node = dequeueNode()
        node.configure(metrics: layout.metrics)
        let token = node.assign(card: card, row: key.row, column: key.column, keepingFace: false)
        node.place(slot: slot(for: key))
        cardsRoot.addChildNode(node)
        mounted[key] = node

        requestFace(for: node, card: card, key: key, token: token)
    }

    private func unmount(_ key: CardKey) {
        guard let node = mounted.removeValue(forKey: key) else { return }
        cancelTasks(for: node)
        node.removeFromParentNode()
        node.clear()
        if nodePool.count < 48 { nodePool.append(node) }
    }

    private func unmountAll() {
        for key in mounted.keys { unmount(key) }
    }

    private func dequeueNode() -> LiveWallCardNode {
        nodePool.popLast() ?? LiveWallCardNode()
    }

    private func cancelTasks(for node: LiveWallCardNode) {
        let id = ObjectIdentifier(node)
        nodeTasks[id]?.forEach { $0.cancel() }
        nodeTasks[id] = nil
    }

    private func track(_ task: Task<Void, Never>, for node: LiveWallCardNode) {
        nodeTasks[ObjectIdentifier(node), default: []].append(task)
    }

    // MARK: - Printing a card

    /// Prints a card's face, fetching the programme still first where the card
    /// is near enough the focus to be worth one. A card with no picture is
    /// still printed — a hole in the wall is worse than a plain tile.
    private func requestFace(
        for node: LiveWallCardNode, card: LiveWallCard, key: CardKey, token: UUID
    ) {
        cancelTasks(for: node)

        let slot = slot(for: key)
        let emphasis = slot.isFocused
        let accent = palette.accent(bands[key.row].accentIndex)
        let palette = palette
        let aspect = CGFloat(layout.metrics.cardAspect)
        let wantsArt = layout.wantsArtwork(
            columnOffset: slot.columnOffset, rowOffset: slot.rowOffset)

        if let glow = LiveWallTextures.cardGlow(accent: accent) {
            node.applyGlow(glow, generation: token)
        }

        let url = wantsArt ? artwork?.still(card, emphasis ? 720 : 420) : nil

        guard let url else {
            let printTask = Task.detached(priority: .userInitiated) { [weak node] in
                let printed = LiveWallTextures.cardFace(
                    card: card, art: nil, accent: accent, palette: palette,
                    emphasis: emphasis, maxPixel: emphasis ? 1100 : 700)
                guard !Task.isCancelled, let printed else { return }
                await MainActor.run { node?.applyFace(printed, hasArtwork: false, generation: token) }
            }
            track(printTask, for: node)
            return
        }

        let faceTask = Task { [weak node] in
            let image = try? await ImageLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            let source = image.flatMap { LiveWallTextures.sourceImage(for: url, from: $0) }
            let printed = await Task.detached(priority: .userInitiated) {
                LiveWallTextures.cardFace(
                    card: card, art: source, accent: accent, palette: palette,
                    emphasis: emphasis, maxPixel: emphasis ? 1100 : 700)
            }.value
            guard !Task.isCancelled, let printed else { return }
            node?.applyFace(printed, hasArtwork: source != nil, generation: token)
        }
        track(faceTask, for: node)
        _ = aspect
    }

    /// Reprints a few cards — the ones a change of focus actually altered.
    /// Each keeps its current face until the new one arrives.
    private func reprint(_ keys: [CardKey]) {
        for key in Set(keys) {
            guard let node = mounted[key], key.row < bands.count else { continue }
            let cards = bands[key.row].cards
            guard key.column < cards.count else { continue }
            let card = cards[key.column]
            let token = node.assign(card: card, row: key.row, column: key.column, keepingFace: true)
            requestFace(for: node, card: card, key: key, token: token)
        }
    }

    /// Reprints everything mounted, for when the television itself changed —
    /// new programmes, a new lineup. Faces stay up while their replacements
    /// are drawn, so even a whole-wall reprint never shows a blank card.
    func refreshFaces() {
        reprint(Array(mounted.keys))
    }

    // MARK: - Input

    func focusSceneView() {
        #if os(macOS)
        view?.window?.makeFirstResponder(view)
        #else
        view?.becomeFirstResponder()
        #endif
    }

    func handleTap(at point: CGPoint) {
        guard let view else { return }
        let hits = view.hitTest(point, options: [
            .categoryBitMask: LiveWallCardNode.hitTestCategory,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
        ])
        guard let node = hits.compactMap({ $0.node.cardNode }).first else { return }

        if node.rowIndex == focusedRow && node.columnIndex == focusedColumn {
            if let card = focusedCard { onPlay?(card) }
            return
        }
        focus(row: node.rowIndex, column: node.columnIndex, animated: true)
    }
}

private extension SCNNode {
    /// The card a hit belongs to, whether the hit landed on the card's face or
    /// on the card itself.
    var cardNode: LiveWallCardNode? {
        self as? LiveWallCardNode ?? parent as? LiveWallCardNode
    }
}
