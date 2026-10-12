#if DEBUG
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `-GuideBench 1`: once the guide has settled, drive the grid along a fixed
/// path one display frame at a time and report the frames that missed.
///
///   -GuideBench 1           run it (with -GuideAuto 1 -GuideFixture 1)
///   -GuideStressChannels N  the lineup size to scroll through
///   -GuideQuit 1            exit once the report is written
///
/// Two kinds of motion, because the platforms scroll two ways. "Drag" moves the
/// grid by a fixed velocity every frame, the way a trackpad or a finger does;
/// "press" fires short animated steps at remote-repeat pace, the way a held
/// direction on the Siri Remote does. Each phase reports frames, hitches
/// (frames that took more than 1.5 intervals), and the worst frame.
///
/// Counters tally how often the guide's main views evaluated their bodies over
/// the whole run — the number that says whether a scroll is rebuilding the
/// screen or only moving it.
enum GuideBench {
    static let isActive = UserDefaults.standard.object(forKey: "GuideBench") != nil

    @MainActor private static var counters: [String: Int] = [:]
    @MainActor private static var isRunning = false

    /// Call from a body: `let _ = GuideBench.tally("lane")`.
    @MainActor static func tally(_ key: String) {
        guard isActive else { return }
        counters[key, default: 0] += 1
    }

    @MainActor static func resetCounters() { counters = [:] }

    @MainActor static func report(_ line: String) {
        FileHandle.standardError.write(Data("guide-bench: \(line)\n".utf8))
    }

    struct Phase {
        enum Kind { case drag(CGVector), press(CGVector, every: Double, animation: Double) }
        var name: String
        var kind: Kind
        var duration: Double
    }

    /// The path. Long enough on each axis to leave the rows that were built
    /// at launch behind, so what is measured is rows arriving.
    static func phases(rowPitch: CGFloat, page: CGFloat) -> [Phase] {
        #if os(tvOS)
        return [
            Phase(name: "press-down", kind: .press(CGVector(dx: 0, dy: rowPitch), every: 0.16, animation: 0.2), duration: 4),
            Phase(name: "press-up", kind: .press(CGVector(dx: 0, dy: -rowPitch), every: 0.16, animation: 0.2), duration: 4),
            Phase(name: "press-right", kind: .press(CGVector(dx: page, dy: 0), every: 0.4, animation: 0.28), duration: 4),
            Phase(name: "press-left", kind: .press(CGVector(dx: -page, dy: 0), every: 0.4, animation: 0.28), duration: 4),
        ]
        #else
        return [
            Phase(name: "drag-down", kind: .drag(CGVector(dx: 0, dy: 2400)), duration: 3),
            Phase(name: "drag-up", kind: .drag(CGVector(dx: 0, dy: -2400)), duration: 3),
            Phase(name: "drag-right", kind: .drag(CGVector(dx: 2400, dy: 0)), duration: 3),
            Phase(name: "drag-left", kind: .drag(CGVector(dx: -2400, dy: 0)), duration: 3),
            Phase(name: "drag-diagonal", kind: .drag(CGVector(dx: 1400, dy: 1400)), duration: 3),
        ]
        #endif
    }

    /// Run the path. `scroll` moves the grid to a point, animated over the
    /// given duration when it is above zero.
    @MainActor
    static func run(
        rowPitch: CGFloat, page: CGFloat, limit: @escaping @MainActor () -> CGSize,
        scroll: @escaping @MainActor (CGPoint, Double) -> Void
    ) async {
        do { try await Task.sleep(for: .seconds(GuideAutopilot.settleSeconds)) } catch { return }
        // One run per process: the guide can be built twice on the way to
        // its window, and two benches scrolling one grid measure nothing.
        guard !isRunning else { return }
        isRunning = true
        let ticker = GuideFrameTicker()
        guard ticker.start() else {
            report("no display link")
            return
        }
        defer { ticker.stop() }
        var origin = CGPoint.zero
        scroll(origin, 0)
        _ = await ticker.next()
        _ = await ticker.next()
        resetCounters()
        var totals = (frames: 0, hitches: 0, dropped: 0, busy: CFTimeInterval(0))
        for phase in phases(rowPitch: rowPitch, page: page) {
            let start = await ticker.next().timestamp
            ticker.resetStats()
            var nextPress = start
            var point = origin
            while true {
                let tick = await ticker.next()
                let elapsed = tick.timestamp - start
                if elapsed >= phase.duration { break }
                let bound = limit()
                switch phase.kind {
                case .drag(let velocity):
                    point = CGPoint(x: origin.x + velocity.dx * elapsed, y: origin.y + velocity.dy * elapsed)
                    point = clamp(point, bound)
                    scroll(point, 0)
                case .press(let step, let every, let animation):
                    guard tick.timestamp >= nextPress else { continue }
                    nextPress += every
                    point = clamp(CGPoint(x: point.x + step.dx, y: point.y + step.dy), bound)
                    scroll(point, animation)
                }
            }
            origin = point
            let stats = ticker.stats
            totals.frames += stats.frames
            totals.hitches += stats.hitches
            totals.dropped += stats.dropped
            totals.busy += stats.busy
            report(String(format: "%@ frames=%d hitches=%d dropped=%d worst=%.1fms interval=%.1fms busy=%.2fms/frame",
                          phase.name, stats.frames, stats.hitches, stats.dropped,
                          stats.worst * 1000, stats.interval * 1000,
                          stats.busy * 1000 / Double(max(stats.frames, 1))))
        }
        report(String(format: "total frames=%d hitches=%d dropped=%d busy=%.2fms/frame",
                      totals.frames, totals.hitches, totals.dropped,
                      totals.busy * 1000 / Double(max(totals.frames, 1))))
        report("bodies " + counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        if GuideAutopilot.quitAfterShot { exit(0) }
    }

    private static func clamp(_ point: CGPoint, _ bound: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(bound.width, 0)),
                y: min(max(point.y, 0), max(bound.height, 0)))
    }
}

/// Display-frame clock for the bench: hands out one tick per frame and keeps
/// interval statistics since the last reset.
@MainActor
final class GuideFrameTicker: NSObject {
    struct Tick { var timestamp: CFTimeInterval }
    struct Stats {
        var frames = 0
        var hitches = 0
        var dropped = 0
        var worst: CFTimeInterval = 0
        var interval: CFTimeInterval = 0
        /// Main-thread time spent awake, summed: the work the frames cost,
        /// whether or not the display rate let it show as a miss.
        var busy: CFTimeInterval = 0
    }

    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Tick, Never>] = []
    private var last: CFTimeInterval?
    private(set) var stats = Stats()
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFTimeInterval?

    func start() -> Bool {
        #if os(macOS)
        guard let screen = NSScreen.main else { return false }
        let link = screen.displayLink(target: self, selector: #selector(fire(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    self.wokeAt = now
                } else if let woke = self.wokeAt {
                    self.stats.busy += now - woke
                    self.wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    func resetStats() {
        stats = Stats()
        last = nil
    }

    func next() async -> Tick {
        await withCheckedContinuation { waiters.append($0) }
    }

    @objc private func fire(_ link: CADisplayLink) {
        let now = link.timestamp
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { stats.interval = interval }
        if let last {
            let delta = now - last
            stats.frames += 1
            stats.worst = max(stats.worst, delta)
            if interval > 0, delta > interval * 1.5 {
                stats.hitches += 1
                stats.dropped += max(Int((delta / interval).rounded()) - 1, 1)
            }
        }
        last = now
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: Tick(timestamp: now)) }
    }
}


/// Attaches the bench to the grid's scroll view when `-GuideBench` is set.
/// The bench moves the grid through the guide's own scroll requests, the same
/// path the pager and the remote take.
struct GuideBenchHook: ViewModifier {
    var rowPitch: CGFloat
    var page: CGFloat
    var limit: @MainActor () -> CGSize
    var scroll: @MainActor (CGPoint, Double) -> Void

    func body(content: Content) -> some View {
        if GuideBench.isActive {
            content.task {
                await GuideBench.run(rowPitch: rowPitch, page: page, limit: limit, scroll: scroll)
            }
        } else {
            content
        }
    }
}
#endif
