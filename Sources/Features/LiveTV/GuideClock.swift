import Foundation

/// The guide's idea of "now".
///
/// Everything in the guide that draws or decides against the current time goes
/// through here rather than calling `Date()`, so a screenshot run can pin the
/// clock and produce the same frame every time. Without a pin this is just
/// `Date()`.
enum GuideClock {
    static var now: Date {
        #if DEBUG
        if let pinned = GuideAutopilot.pinnedNow { return pinned }
        #endif
        return Date()
    }

    /// Start of the window the grid is drawn from: the previous half-hour
    /// boundary. A little already-aired time stays visible on the left, which
    /// is what keeps the leftmost cells from looking truncated mid-word.
    static func windowStart(for date: Date = GuideClock.now) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let boundary = (minutes / 30) * 30
        return calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(boundary * 60))
    }
}
