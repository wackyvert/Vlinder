#if DEBUG
import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif

/// Launch-argument autopilot for deterministic Live TV Atrium screenshots —
/// drives the real app, against the real server, to a known card:
///
///   -LiveWallAuto 1        open Live TV in the Atrium presentation
///   -LiveWallRow 1         park on this band after the guide loads
///   -LiveWallColumn 3      park on this card within the band
///
/// The window size and appearance overrides are shared with the library
/// Atrium's autopilot (-AtriumAutoWindow, -AtriumAutoAppearance), so one
/// screenshot harness drives both rooms.
enum LiveWallAutopilot {
    private static var defaults: UserDefaults { .standard }

    static var isActive: Bool {
        defaults.object(forKey: "LiveWallAuto") != nil
    }

    struct Target {
        var row: Int
        var column: Int
    }

    /// Where to write a PNG of the wall, and how big to render it.
    static var shotPath: String? {
        defaults.string(forKey: "LiveWallShot")
    }

    static var shotSize: CGSize {
        guard let raw = defaults.string(forKey: "LiveWallShotSize") else {
            return CGSize(width: 1600, height: 900)
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 200, parts[1] > 200 else {
            return CGSize(width: 1600, height: 900)
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Seconds to spend timing the scene, at `-LiveWallBenchSize` (default 4K).
    static var benchSeconds: Double? {
        let value = defaults.double(forKey: "LiveWallBench")
        return value > 0 ? value : nil
    }

    static var benchSize: CGSize {
        guard let raw = defaults.string(forKey: "LiveWallBenchSize") else {
            return CGSize(width: 3840, height: 2160)
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 200, parts[1] > 200 else {
            return CGSize(width: 3840, height: 2160)
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// How long to let programme stills arrive before shooting.
    static var settleSeconds: Double {
        let value = defaults.double(forKey: "LiveWallSettle")
        return value > 0 ? value : 3.0
    }

    /// How long to wait for the guide before giving up and saying so.
    /// Jellyfin's /LiveTv/Channels with addCurrentProgram is slow on a large
    /// lineup, so the default is generous.
    static var deadlineSeconds: Double {
        let value = defaults.double(forKey: "LiveWallDeadline")
        return value > 0 ? value : 240
    }

    static var quitsWhenDone: Bool {
        defaults.object(forKey: "LiveWallQuit") != nil
    }

    /// Ends the run once the harness has what it came for. iOS has no polite
    /// way to quit; for a screenshot harness a plain exit is the polite way.
    @MainActor
    static func quitIfAsked() {
        guard quitsWhenDone else { return }
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
    }

    static var target: Target? {
        guard isActive else { return nil }
        return Target(
            row: defaults.object(forKey: "LiveWallRow") == nil ? 0 : defaults.integer(forKey: "LiveWallRow"),
            column: defaults.object(forKey: "LiveWallColumn") == nil ? 0 : defaults.integer(forKey: "LiveWallColumn"))
    }
}
#endif
