import SwiftUI

/// How a guide control is pressed and, on the TV, how it says it has focus.
///
/// On the desktop every cell is a plain button: the pointer is the cursor and
/// the reference draws no hover state, so there is nothing to add. On tvOS the
/// remote has no pointer — focus *is* the cursor — and the stock plain style
/// answers it with a white platter lifted and scaled under the label. That is
/// what put the oversized halo on the "Today" pill, and on a 1300-point
/// program cell it would be a slab of white the size of the screen. The
/// guide's cells are dark tiles on a near-black page, so the focus mark here
/// is the tile's own outline, drawn in white on its own corner radius, with
/// the fill lifted a shade. Nothing moves and nothing overlaps a neighbour,
/// which matters in a grid whose cells are laid by offset and cannot re-order.
extension View {
    /// `.plain` on the desktop; ring-on-focus on tvOS.
    ///
    /// `cornerRadius` is the shape the ring follows — a cell's, the pill's, or
    /// half a pager disc.
    @ViewBuilder
    func guideButtonStyle(cornerRadius: CGFloat = GuideMetrics.cellCornerRadius) -> some View {
        #if os(tvOS)
        buttonStyle(GuideFocusButtonStyle(cornerRadius: cornerRadius))
        #else
        buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
struct GuideFocusButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    // A lift, not a wash: enough to separate the focused tile
                    // from the lit airing-now band it may be sitting in.
                    .fill(.white.opacity(isFocused ? 0.10 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white, lineWidth: isFocused ? GuideMetrics.focusRingWidth : 0)
            }
            // Press feedback in place of the platform's scale bounce.
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
