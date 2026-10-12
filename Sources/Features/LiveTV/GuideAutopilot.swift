#if DEBUG
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Launch-argument autopilot for deterministic Live TV guide screenshots.
///
///   -GuideAuto 1                    open Live TV on the guide, detail-only
///   -GuideFixture 1                 pin the lineup and the clock
///   -GuideShot /tmp/guide.png       where to write the frame
///   -GuideShotSize 1657x852         window size, and so the frame's size
///   -GuideSettle 6                  seconds to let logos arrive
///   -GuideQuit 1                    exit once the frame is written
///   -GuideScrollTo 1500,2000        scroll the grid there once laid out
///   -GuideInitialChannel ID         tvOS: open on that channel, as in-player
///   -GuideFocus cell:0,1            tvOS: put focus on a control for the shot.
///                                   pill | back | forward | mode | logo:R |
///                                   now:R | cell:R,C  (R = channel row, C =
///                                   cell in that lane, both from 0)
///
/// Same shape as `LiveWallAutopilot`, so one harness idea covers both rooms —
/// but this one shoots the window rather than an SCNRenderer, because the
/// guide is SwiftUI and what matters is what actually lays out.
enum GuideAutopilot {
    private static var defaults: UserDefaults { .standard }

    /// Offline UI checks use fixtures without restoring or contacting an account.
    static var isOffline: Bool { isActive && usesFixture && defaults.bool(forKey: "GuideOffline") }

    static var isActive: Bool { defaults.object(forKey: "GuideAuto") != nil }

    /// Say what the flags actually parsed to — a silently-false fixture flag
    /// otherwise looks exactly like a slow server.
    static func reportFlags() {
        FileHandle.standardError.write(Data(
            "guide-flags: active=\(isActive) fixture=\(usesFixture) size=\(shotSize) settle=\(settleSeconds)\n".utf8))
    }
    static var usesFixture: Bool { defaults.object(forKey: "GuideFixture") != nil }
    static var quitAfterShot: Bool { defaults.object(forKey: "GuideQuit") != nil }
    static var shotPath: String? { defaults.string(forKey: "GuideShot") }

    /// Where `-GuideFocus` asks the remote's focus to be. The simulator takes
    /// no remote input from `simctl`, so a focus state can only be photographed
    /// by having the guide put focus there itself once it has laid out.
    enum FocusTarget {
        case dayPill, pageBack, pageForward, modeSwitch
        case logo(row: Int), nowPlaying(row: Int)
        case cell(row: Int, column: Int)
    }

    static var focusTarget: FocusTarget? {
        guard let raw = defaults.string(forKey: "GuideFocus")?.lowercased() else { return nil }
        switch raw {
        case "pill": return .dayPill
        case "back": return .pageBack
        case "forward": return .pageForward
        case "mode": return .modeSwitch
        default: break
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let numbers = parts[1].split(separator: ",").compactMap { Int($0) }
        switch (parts[0], numbers.count) {
        case ("logo", 1): return .logo(row: numbers[0])
        case ("now", 1): return .nowPlaying(row: numbers[0])
        case ("cell", 2): return .cell(row: numbers[0], column: numbers[1])
        default: return nil
        }
    }

    /// `-GuideScrollTo X,Y`: where to scroll the grid once it has laid out, so
    /// a shot can photograph the pinned columns and ruler mid-grid.
    static var scrollTarget: CGPoint? {
        guard let raw = defaults.string(forKey: "GuideScrollTo") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    /// `-GuideInitialChannel <id>`: open the TV guide the way the in-player
    /// guide does, scrolled to and focused on that channel's row.
    static var initialChannel: String? {
        guard isActive else { return nil }
        return defaults.string(forKey: "GuideInitialChannel")
    }

    /// Log a tap on the guide under the harness, so a scripted tap can say
    /// which view actually received it.
    static func reportTap(_ target: String, _ channelId: String) {
        guard isActive else { return }
        FileHandle.standardError.write(Data("guide-tap: \(target) \(channelId)\n".utf8))
    }

    /// The pinned clock, so the now-marker and the airing-now cells land in the
    /// same place every run. Only pinned in fixture mode.
    static var pinnedNow: Date? {
        guard isActive, usesFixture else { return nil }
        return GuideFixture.pinnedNow
    }

    static var shotSize: CGSize {
        guard let raw = defaults.string(forKey: "GuideShotSize") else {
            return CGSize(width: 1657, height: 852)
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 200, parts[1] > 200 else {
            return CGSize(width: 1657, height: 852)
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    static var settleSeconds: Double {
        let value = defaults.double(forKey: "GuideSettle")
        return value > 0 ? value : 6.0
    }

    #if os(macOS)
    private static var didReport = false

    /// Identify the window to capture, and how much of it is titlebar.
    ///
    /// The harness shoots by window id, not by screen region: a region grab
    /// photographs whatever happens to be on top, which silently produces a
    /// screenshot of some other app and a critic's confident verdict on it.
    ///
    /// The frame comes off the real composited window rather than an
    /// `ImageRenderer` pass, because rendering offscreen never materialises the
    /// grid's lazy stacks — it would photograph an empty guide.
    static func reportRect(settle: Double? = nil) {
        guard isActive, !didReport else { return }
        didReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (settle ?? settleSeconds)) {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView
            else {
                FileHandle.standardError.write(Data("guide-rect: no window\n".utf8))
                return
            }
            let chrome = window.frame.height - view.bounds.height
            FileHandle.standardError.write(Data(
                "guide-window: \(window.windowNumber)\n".utf8))
            FileHandle.standardError.write(Data(
                "guide-content: \(Int(view.bounds.width))x\(Int(view.bounds.height)) chrome=\(Int(chrome))\n".utf8))
        }
    }

    #endif
}
#endif
