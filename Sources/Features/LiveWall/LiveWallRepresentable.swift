import SceneKit
import SwiftUI

// The wall's SceneKit host, one per platform. There is no camera control on
// either: the viewer stands still and the wall moves. Running sideways moves
// along the band, a deliberate vertical move changes band, arrows step, Return
// and Space tune the channel, Escape leaves.

private extension SCNView {
    /// The renderer settings both hosts share.
    func configureForWall(scene: SCNScene) {
        self.scene = scene
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        // 2x: at 4K the difference from 4x is invisible from the sofa and
        // the frame time is not.
        antialiasingMode = .multisampling2X
        rendersContinuously = false
        isJitteringEnabled = false
        backgroundColor = .black
    }
}

#if os(macOS)
import AppKit

/// AppKit host: scrolling sideways runs along the band, scrolling up and down
/// changes band, and the keyboard drives it once the view has focus.
final class LiveWallSCNView: SCNView {
    weak var controller: LiveWallSceneController?

    private var settleWorkItem: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // A wall has two axes, so unlike the shelf the gesture has to pick one:
        // sideways runs along the band, and a deliberate vertical flick steps
        // to the next band rather than scrolling anything.
        if abs(dy) > abs(dx) * 1.6 {
            guard event.phase.contains(.began) || event.momentumPhase.isEmpty else { return }
            guard abs(dy) > 6 else { return }
            controller.handle(dy > 0 ? .up : .down)
            return
        }

        let delta = controller.layout.focusDelta(
            forScrollPoints: Float(-dx), precise: event.hasPreciseScrollingDeltas)
        controller.sift(by: delta)
        scheduleSettle()
    }

    /// A flick leaves the wall between two cards; it should come to rest on one.
    private func scheduleSettle() {
        settleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.controller?.settle()
        }
        settleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.handleTap(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: controller.handle(.left)
        case 124: controller.handle(.right)
        case 126: controller.handle(.up)
        case 125: controller.handle(.down)
        case 36, 76, 49: controller.handle(.play)     // return, keypad enter, space
        case 53: controller.handle(.escape)
        default: return super.keyDown(with: event)
        }
    }
}

struct LiveWallRepresentable: NSViewRepresentable {
    let controller: LiveWallSceneController

    func makeNSView(context: Context) -> LiveWallSCNView {
        let view = LiveWallSCNView()
        view.configureForWall(scene: controller.scene)
        view.controller = controller
        controller.view = view
        return view
    }

    func updateNSView(_ view: LiveWallSCNView, context: Context) {
        view.controller = controller
        controller.view = view
    }
}

#else
import UIKit

/// UIKit host: a finger dragged sideways runs along the band and a flick
/// carries on before settling on a card; a clear vertical swipe steps to the
/// next band; a tap focuses the card under it, and a second tap tunes it. A
/// hardware keyboard (iPad) drives it exactly as on the Mac.
final class LiveWallSCNView: SCNView {
    weak var controller: LiveWallSceneController?

    /// What a drag turned out to be, decided from its first clear movement.
    private enum PanIntent { case undecided, alongBand, bandChanged }
    private var panIntent: PanIntent = .undecided
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

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let controller else { return }
        switch gesture.state {
        case .began:
            panIntent = .undecided
            lastPanX = 0

        case .changed:
            let translation = gesture.translation(in: self)
            if panIntent == .undecided {
                // Wait for the finger to commit before reading its direction.
                guard hypot(translation.x, translation.y) > Self.intentDistance else { return }
                if abs(translation.y) > abs(translation.x) * 1.6 {
                    // The wall follows the finger: pulled down, the band above
                    // comes into view.
                    controller.handle(translation.y > 0 ? .up : .down)
                    panIntent = .bandChanged
                    return
                }
                panIntent = .alongBand
            }
            guard panIntent == .alongBand else { return }
            let dx = translation.x - lastPanX
            lastPanX = translation.x
            controller.sift(by: controller.layout.focusDelta(
                forScrollPoints: Float(-dx), precise: true))

        case .ended, .cancelled, .failed:
            guard panIntent == .alongBand else { return }
            let velocity = gesture.velocity(in: self).x
            controller.sift(by: controller.layout.focusDelta(
                forScrollPoints: Float(-velocity) * Self.flickCarrySeconds, precise: true))
            controller.settle()

        default:
            break
        }
    }

    /// Movement before a drag is read as one direction or the other.
    private static let intentDistance: CGFloat = 8
    /// How much of a flick's velocity becomes travel: the points the wall
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
            case .keyboardLeftArrow: controller.handle(.left)
            case .keyboardRightArrow: controller.handle(.right)
            case .keyboardUpArrow: controller.handle(.up)
            case .keyboardDownArrow: controller.handle(.down)
            case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar: controller.handle(.play)
            case .keyboardEscape: controller.handle(.escape)
            default: continue
            }
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

struct LiveWallRepresentable: UIViewRepresentable {
    let controller: LiveWallSceneController

    func makeUIView(context: Context) -> LiveWallSCNView {
        let view = LiveWallSCNView(frame: .zero)
        view.configureForWall(scene: controller.scene)
        view.controller = controller
        controller.view = view
        return view
    }

    func updateUIView(_ view: LiveWallSCNView, context: Context) {
        view.controller = controller
        controller.view = view
    }
}
#endif
