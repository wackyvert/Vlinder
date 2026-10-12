import Foundation

/// Only materialize artwork near the viewport. Prefix/suffix spacers retain
/// exact row positions, including short group headers, without offscreen views.
struct GuideViewport {
    let range: Range<Int>
    let top: CGFloat
    let bottom: CGFloat

    init(heights: [CGFloat], offset: CGFloat, height: CGFloat, buffer: CGFloat) {
        let lower = max(0, offset - buffer)
        let upper = max(0, offset) + max(height, 1) + buffer
        var y: CGFloat = 0
        var first = heights.count
        var last = heights.count
        var top: CGFloat = 0
        var end: CGFloat = 0
        for (index, rowHeight) in heights.enumerated() {
            let next = y + rowHeight
            if next > lower && y < upper {
                if first == heights.count { first = index; top = y }
                last = index + 1
                end = next
            }
            y = next
        }
        range = first..<last
        self.top = range.isEmpty ? y : top
        bottom = range.isEmpty ? 0 : max(0, y - end)
    }
}
