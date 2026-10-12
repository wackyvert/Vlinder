#if os(macOS)
import AppKit
import SwiftUI

/// Hands the whole window to the player for as long as it is on screen: no
/// toolbar, no window title, no traffic lights, black background. The player's
/// own chrome supplies close/next/previous, and Esc still dismisses.
///
/// Without this the NavigationSplitView toolbar keeps drawing above the video —
/// repeating the title the overlay already shows, offering a second way back,
/// and carving a dead band off the top so the letterboxing sits off-centre.
/// Everything touched is snapshotted and put back when the player goes away.
struct PlayerWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeTakeoverView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeTakeoverView: NSView {
    private struct Snapshot {
        let styleMask: NSWindow.StyleMask
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let toolbarWasVisible: Bool?
        let backgroundColor: NSColor
        let acceptsMouseMovedEvents: Bool
        let hiddenButtons: [(NSWindow.ButtonType, Bool)]
    }

    private static let managedButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private weak var managed: NSWindow?
    private var snapshot: Snapshot?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            restore()
            return
        }
        guard window !== managed else { return }
        restore()
        takeOver(window)
    }

    deinit {
        // Teardown can beat viewDidMoveToWindow(nil); the window must never be
        // left titleless and buttonless.
        restore()
    }

    private func takeOver(_ window: NSWindow) {
        snapshot = Snapshot(
            styleMask: window.styleMask,
            titleVisibility: window.titleVisibility,
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            toolbarWasVisible: window.toolbar?.isVisible,
            backgroundColor: window.backgroundColor,
            acceptsMouseMovedEvents: window.acceptsMouseMovedEvents,
            hiddenButtons: Self.managedButtons.map { ($0, window.standardWindowButton($0)?.isHidden ?? false) })
        managed = window

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar?.isVisible = false
        window.backgroundColor = .black
        // Local mouse-moved monitors only see events if the window asks for them.
        window.acceptsMouseMovedEvents = true
        for button in Self.managedButtons {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    private func restore() {
        defer {
            managed = nil
            snapshot = nil
        }
        guard let window = managed, let saved = snapshot else { return }

        // Native full screen is the window's business, not ours — whatever the
        // user did with AVKit's full-screen button survives the restore.
        var mask = saved.styleMask
        if window.styleMask.contains(.fullScreen) {
            mask.insert(.fullScreen)
        } else {
            mask.remove(.fullScreen)
        }
        window.styleMask = mask
        window.titleVisibility = saved.titleVisibility
        window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
        if let wasVisible = saved.toolbarWasVisible {
            window.toolbar?.isVisible = wasVisible
        }
        window.backgroundColor = saved.backgroundColor
        window.acceptsMouseMovedEvents = saved.acceptsMouseMovedEvents
        for (button, wasHidden) in saved.hiddenButtons {
            window.standardWindowButton(button)?.isHidden = wasHidden
        }
    }
}

/// Reports pointer activity anywhere in the app.
///
/// A local NSEvent monitor rather than `onContinuousHover`: AVPlayerView is an
/// AppKit view sitting in front of the SwiftUI surface and owns the tracking
/// areas over the video, so SwiftUI hover never fires where it matters most.
struct PointerActivityMonitor: View {
    let onActivity: () -> Void

    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel]
                ) { event in
                    onActivity()
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif
