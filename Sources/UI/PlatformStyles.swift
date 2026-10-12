import SwiftUI

extension View {
    /// A bordered text field where the platform draws one. tvOS has no
    /// `.roundedBorder`; its focus engine supplies the field's chrome.
    func fieldStyle() -> some View {
        #if os(tvOS)
        textFieldStyle(.automatic)
        #else
        textFieldStyle(.roundedBorder)
        #endif
    }

    /// Text selection where a pointer exists to select with.
    func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    /// A row-shaped button: unadorned where a pointer hovers over it, but on
    /// tvOS the default (bordered) style so the focus engine has a platter to
    /// lift — a `.plain` button on tvOS gives no visible focus at all.
    func rowButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.automatic)
        #else
        buttonStyle(.plain)
        #endif
    }

    /// A tile-shaped button (poster, account avatar): plain on pointer
    /// platforms where the tile draws its own chrome; tvOS's `.card` style
    /// lifts and shadows the whole tile under focus.
    func tileButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// Ten-foot layout metrics. tvOS's type scale already makes text bigger, but
/// fixed point sizes and column widths tuned for a laptop window read as a
/// phone-width strip in a 1920pt-wide frame.
enum TenFoot {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif

    /// Width of a centred single-column card.
    static var cardWidth: CGFloat { isTV ? 1040 : 440 }
    /// Padding inside that card.
    static var cardPadding: CGFloat { isTV ? 44 : 24 }
    /// Vertical rhythm inside a card.
    static var cardSpacing: CGFloat { isTV ? 26 : 14 }
}
