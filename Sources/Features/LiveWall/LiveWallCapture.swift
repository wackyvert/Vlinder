#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import Metal
import SceneKit
import UniformTypeIdentifiers

/// Offscreen capture and timing for the Live TV Atrium.
///
/// Shooting through an `SCNRenderer` rather than the window means the frame is
/// exactly the size asked for, independent of the sidebar, the toolbar and the
/// display's scale — so two shots taken a week apart are comparable, and a
/// 4K timing run does not need a 4K window.
enum LiveWallCapture {
    private static let device = MTLCreateSystemDefaultDevice()

    private static func renderer(scene: SCNScene, pointOfView: SCNNode) -> SCNRenderer? {
        guard let device else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.autoenablesDefaultLighting = false
        return renderer
    }

    /// One frame, written as a PNG.
    @discardableResult
    static func shoot(
        scene: SCNScene, pointOfView: SCNNode, size: CGSize, to path: String
    ) -> Bool {
        guard let renderer = renderer(scene: scene, pointOfView: pointOfView) else { return false }
        let image = renderer.snapshot(
            atTime: CACurrentMediaTime(), with: size,
            antialiasingMode: .multisampling4X)

        // The snapshot comes back backed by a Metal texture, which has no TIFF
        // representation to go through — take its CGImage and encode that.
        #if os(macOS)
        var frame = CGRect(origin: .zero, size: size)
        let cgImage = image.cgImage(forProposedRect: &frame, context: nil, hints: nil)
        #else
        let cgImage = image.cgImage
        #endif
        guard let cgImage else {
            FileHandle.standardError.write(Data("wall-shot: no CGImage from snapshot\n".utf8))
            return false
        }

        // The app is sandboxed, so the project directory is not writable from
        // in here. Try where we were asked, then fall back to the container's
        // own tmp and say where the file actually landed — the harness outside
        // copies it out.
        let asked = URL(fileURLWithPath: path)
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(asked.lastPathComponent)

        for url in [asked, fallback] {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            print("wall-shot: wrote \(url.path)")
            return true
        }
        FileHandle.standardError.write(Data("wall-shot: could not write \(path)\n".utf8))
        return false
    }

    struct Timing {
        var frames: Int
        var averageFPS: Double
        var p95FrameMilliseconds: Double
        var worstFrameMilliseconds: Double
    }

    /// Renders as fast as it can for `seconds` and reports what the scene costs.
    /// This is the scene's own cost — no window, no compositor — which is the
    /// number worth defending when the wall gets heavier.
    static func benchmark(
        scene: SCNScene, pointOfView: SCNNode, size: CGSize, seconds: Double
    ) -> Timing? {
        guard let renderer = renderer(scene: scene, pointOfView: pointOfView) else { return nil }

        // A first frame pays for shader compilation and texture upload; it is
        // not a frame anyone sees.
        _ = renderer.snapshot(atTime: CACurrentMediaTime(), with: size, antialiasingMode: .none)

        var durations: [Double] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            let frameStart = CACurrentMediaTime()
            _ = renderer.snapshot(
                atTime: frameStart, with: size, antialiasingMode: .multisampling2X)
            durations.append((CACurrentMediaTime() - frameStart) * 1000)
        }
        guard !durations.isEmpty else { return nil }

        let sorted = durations.sorted()
        let total = durations.reduce(0, +)
        return Timing(
            frames: durations.count,
            averageFPS: 1000 * Double(durations.count) / total,
            p95FrameMilliseconds: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            worstFrameMilliseconds: sorted[sorted.count - 1])
    }
}
#endif
