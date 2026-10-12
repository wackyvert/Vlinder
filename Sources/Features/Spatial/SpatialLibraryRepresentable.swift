import SceneKit
import SwiftUI

// The Atrium's SceneKit host, one per platform. Both turn native input into the
// controller's abstract commands; there is no camera control on either. The
// shelf is sifted along, a case is picked up, arrows step to the neighbouring
// case, Return opens it — into the show's own shelf when it has one — Space
// plays it, and Escape puts it back, then backs out of the shelf it came from.

private extension SCNView {
    /// The renderer settings both hosts share.
    func configureForAtrium(scene: SCNScene) {
        self.scene = scene
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        antialiasingMode = .multisampling4X
        rendersContinuously = false
        isJitteringEnabled = false
    }
}

#if os(macOS)
import AppKit

/// AppKit host: scrolling sifts along the shelf, clicking picks a case up, and
/// the keyboard drives it once the view has focus.
final class AtriumSCNView: SCNView {
    weak var controller: SpatialLibrarySceneController?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        // Either axis sifts: a horizontal swipe is the natural gesture along a
        // shelf, and a vertical wheel is what a mouse has. Take the dominant
        // one so a diagonal swipe can't cancel itself out.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let points = abs(dx) >= abs(dy) ? -dx : -dy
        let delta = controller.layout.focusDelta(
            forScrollPoints: Float(points), precise: event.hasPreciseScrollingDeltas)
        controller.sift(by: delta)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.handleTap(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: controller?.handle(.previous)   // left, up
        case 124, 125: controller?.handle(.next)       // right, down
        case 36, 76: controller?.handle(.activate)     // return, keypad enter
        case 49: controller?.handle(.play)             // space
        case 53: controller?.handle(.escape)
        default: super.keyDown(with: event)
        }
    }
}

struct SpatialLibraryRepresentable: NSViewRepresentable {
    let controller: SpatialLibrarySceneController

    func makeNSView(context: Context) -> AtriumSCNView {
        let view = AtriumSCNView()
        view.configureForAtrium(scene: controller.scene)
        view.controller = controller
        controller.view = view
        return view
    }

    func updateNSView(_ view: AtriumSCNView, context: Context) {
        view.controller = controller
        controller.view = view
    }
}

#else
import UIKit

/// UIKit host: a finger drags the shelf along and a flick carries it on a little
/// before it settles on a case; a tap picks the case under it up. A hardware
/// keyboard (iPad) drives it exactly as on the Mac.
final class AtriumSCNView: SCNView {
    weak var controller: SpatialLibrarySceneController?

    private var lastPanX: CGFloat = 0

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        installGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installGestures()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.adaptCamera(toViewSize: bounds.size)
    }

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    /// The shelf follows the finger — dragging right brings the cases on the
    /// left round, the same way the trackpad does — and a flick at the end
    /// carries it on in proportion to how hard it was thrown.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let controller else { return }
        switch gesture.state {
        case .began:
            lastPanX = 0
        case .changed:
            let x = gesture.translation(in: self).x
            let dx = x - lastPanX
            lastPanX = x
            controller.sift(by: controller.layout.focusDelta(
                forScrollPoints: Float(-dx), precise: true))
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: self).x
            controller.sift(by: controller.layout.focusDelta(
                forScrollPoints: Float(-velocity) * Self.flickCarrySeconds, precise: true))
            controller.settle()
        default:
            break
        }
    }

    /// How much of a flick's velocity becomes travel: the points the shelf
    /// would cover in this many seconds at the speed the finger left it.
    private static let flickCarrySeconds: Float = 0.08

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        becomeFirstResponder()
        controller?.handleTap(at: gesture.location(in: self))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let controller else { return super.pressesBegan(presses, with: event) }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardLeftArrow, .keyboardUpArrow: controller.handle(.previous)
            case .keyboardRightArrow, .keyboardDownArrow: controller.handle(.next)
            case .keyboardReturnOrEnter, .keypadEnter: controller.handle(.activate)
            case .keyboardSpacebar: controller.handle(.play)
            case .keyboardEscape: controller.handle(.escape)
            default: continue
            }
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

struct SpatialLibraryRepresentable: UIViewRepresentable {
    let controller: SpatialLibrarySceneController

    func makeUIView(context: Context) -> AtriumSCNView {
        let view = AtriumSCNView(frame: .zero)
        view.configureForAtrium(scene: controller.scene)
        view.controller = controller
        controller.view = view
        return view
    }

    func updateUIView(_ view: AtriumSCNView, context: Context) {
        view.controller = controller
        controller.view = view
    }
}
#endif
