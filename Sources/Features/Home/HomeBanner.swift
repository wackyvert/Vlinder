import Combine
import SwiftUI

/// Auto-advancing hero carousel over next-up / continue-watching items
/// (Fladder's HomeBannerWidget, "combined" style).
struct HomeBanner: View {
    let items: [BaseItem]

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var index = 0
    /// True while any banner control has focus. The card is rebuilt per item,
    /// so advancing under a focused Play button would throw focus elsewhere.
    @FocusState private var bannerFocused: Bool
    @Namespace private var focusScope

    private let advanceInterval: TimeInterval = 8

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            banner
                .onReceive(Timer.publish(every: advanceInterval, on: .main, in: .common).autoconnect()) { _ in
                    guard items.count > 1, !bannerFocused else { return }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        index = (index + 1) % items.count
                    }
                }
        }
    }

    private var currentItem: BaseItem {
        items[min(index, items.count - 1)]
    }

    @ViewBuilder
    private var banner: some View {
        #if os(iOS)
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                BannerCard(item: item)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxHeight: 420)
        #elseif os(tvOS)
        // The card keeps one identity across items so a focused Play survives
        // an auto-advance; only the backdrop swaps and fades (see BannerCard).
        ZStack(alignment: .bottomTrailing) {
            BannerCard(item: currentItem, focusScope: focusScope)

            HStack(spacing: 18) {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(TVPillButtonStyle(compact: true))
                Text("\(index + 1) / \(items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(TVPillButtonStyle(compact: true))
            }
            // Same 80pt safe margin the text and shelves use, so the hero's
            // controls and the shelf cards share a right edge.
            .padding(.horizontal, TVHome.margin)
            .padding(.bottom, 44) // matches BannerCard.Metrics.bottomInset so the pager sits on the buttons' baseline
        }
        .frame(height: TVHome.bannerHeight)
        .animation(.easeInOut(duration: 0.3), value: index)
        .focused($bannerFocused)
        .focusScope(focusScope)
        #else
        ZStack(alignment: .bottomTrailing) {
            BannerCard(item: currentItem)
                .id(currentItem.id)
                .transition(.opacity)

            HStack(spacing: 8) {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Text("\(index + 1) / \(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .aspectRatio(21 / 9, contentMode: .fit)
        .frame(maxHeight: 380)
        .animation(.easeInOut(duration: 0.3), value: index)
        #endif
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }
}

struct BannerCard: View {
    let item: BaseItem
    /// Scope in which Play takes default focus, so landing on Home puts the
    /// remote on the thing a viewer most likely wants. tvOS only.
    var focusScope: Namespace.ID?

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @Namespace private var fallbackScope

    #if os(tvOS)
    private enum HeroAction { case play, details }
    @FocusState private var focusedAction: HeroAction?

    /// 1 for the focused pill (or when nothing in the hero is focused), 0.55
    /// for its sibling. -HomeFocusPreview 1 stands in for Play being focused.
    private func dimmed(unless action: HeroAction) -> Double {
        var current = focusedAction
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HomeFocusPreview") { current = .play }
        #endif
        guard let current, current != action else { return 1 }
        return 0.55
    }
    #endif

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork

            VStack(alignment: .leading, spacing: Metrics.textSpacing) {
                if let logoURL = app.client?.imageURL(item.logoRef, maxHeight: Metrics.logoFetchHeight) {
                    RemoteImage(url: logoURL, contentMode: .fit)
                        .frame(maxWidth: Metrics.logoWidth, maxHeight: Metrics.logoHeight, alignment: .leading)
                } else {
                    Text(bannerTitle)
                        .font(Metrics.titleFont)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let subtitle = bannerSubtitle {
                    Text(subtitle)
                        .font(Metrics.subtitleFont)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                actions
                    .padding(.top, Metrics.actionsTopPadding)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, Metrics.inset)
            .padding(.bottom, Metrics.bottomInset)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .padding(.horizontal, Metrics.horizontalMargin)
    }

    #if os(tvOS)
    /// Fades the hero's bottom edge into the page over the last
    /// `Metrics.seamFadeHeight` points. The darkening gradient alone ended at
    /// near-black (≈11,6,3) against the page's ≈48 grey — a hard 1920px line
    /// at the seam. Applied to the art and scrims only; the title and buttons
    /// are outside it so they stay solid.
    private var seamMask: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Metrics.seamFadeHeight)
        }
    }
    #endif

    /// Backdrop plus its scrims; on tvOS the whole stack is masked so it
    /// ramps into the page at the bottom instead of stopping on a hard line.
    @ViewBuilder
    private var artwork: some View {
        let layers = ZStack {
            backdrop
            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom)
            #if os(tvOS)
            // Scrim under the floating tab bar. The bar has no background of
            // its own, so without this its legibility swung with whatever the
            // hero rotated in (luminance 0.02–0.12 along the strip); a constant
            // dark ramp over the top keeps the bar reading the same on every
            // backdrop.
            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.62), .black.opacity(0.3), .clear],
                    startPoint: .top, endPoint: .bottom)
                .frame(height: Metrics.topScrimHeight)
                Spacer(minLength: 0)
            }
            #endif

        }
        #if os(tvOS)
        layers.mask { seamMask }
        #else
        layers
        #endif
    }

    @ViewBuilder
    private var backdrop: some View {
        let image = RemoteImage(url: app.client?.imageURL(item.backdropRef, maxWidth: Metrics.backdropFetchWidth))
        #if os(tvOS)
        // As an overlay the filled image cannot inflate the card past the
        // height the banner set; the clip shape trims the overflow.
        // Aligned to the top and nudged down by a fraction of the overflow,
        // so the 430pt window through a 16:9 backdrop lands on the upper
        // third — where faces are — rather than the centre, which cut every
        // head off at the hairline. GeometryReader so the maths holds for
        // any width the banner is given.
        Color.clear.overlay(alignment: .top) {
            GeometryReader { geo in
                let artHeight = geo.size.width * 9 / 16
                let overflow = max(0, artHeight - geo.size.height)
                image
                    .frame(width: geo.size.width, height: artHeight)
                    .clipped()
                    .offset(y: -overflow * Metrics.cropBias)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        #else
        image
        #endif
    }

    private var playLabel: some View {
        Label(item.resumeTicks != nil ? "Resume" : "Play", systemImage: "play.fill")
    }

    private func play() {
        guard let client = app.client else { return }
        player.play(item: item, client: client, settings: app.settings)
    }

    @ViewBuilder
    private var actions: some View {
        #if os(tvOS)
        // The system bordered styles tinted white lose their label on tvOS
        // (white on white); the pill style paints its own focus state. The
        // unfocused sibling dims so the lit pill is the only bright thing in
        // the hero — under a near-white tab pill, brightness alone was not a
        // signal.
        HStack(spacing: 20) {
            Button(action: play) { playLabel }
                .buttonStyle(TVPillButtonStyle(prominent: true))
                .focused($focusedAction, equals: .play)
                .prefersDefaultFocus(focusScope != nil, in: focusScope ?? fallbackScope)
                .opacity(dimmed(unless: .play))
            NavigationLink(value: item) {
                Text("Details")
            }
            .buttonStyle(TVPillButtonStyle())
            .focused($focusedAction, equals: .details)
            .opacity(dimmed(unless: .details))
        }
        .animation(.easeOut(duration: 0.15), value: focusedAction)
        #else
        HStack(spacing: 10) {
            Button(action: play) {
                playLabel
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)

            NavigationLink(value: item) {
                Text("Details")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        #endif
    }

    /// Desk vs. couch sizing for the hero; the Mac/iOS numbers are unchanged.
    private enum Metrics {
        #if os(tvOS)
        static let textSpacing: CGFloat = 14
        static let logoFetchHeight = 320
        static let backdropFetchWidth = 1920
        static let logoWidth: CGFloat = 460
        static let logoHeight: CGFloat = 130
        static let titleFont: Font = .largeTitle.weight(.bold)
        static let subtitleFont: Font = .title3.weight(.medium)
        static let actionsTopPadding: CGFloat = 12
        /// Artwork bleeds to the screen edges (the Apple TV app never gives a
        /// hero a margin); only the text and buttons keep the safe margin.
        static let inset: CGFloat = TVHome.margin
        static let bottomInset: CGFloat = 44
        static let cornerRadius: CGFloat = 0
        static let horizontalMargin: CGFloat = 0
        /// Fraction of the backdrop's vertical overflow hidden above the
        /// window: 0 shows the very top, 0.5 is a centre crop. 0.22 puts the
        /// window's centre near the upper third of the picture.
        static let cropBias: CGFloat = 0.22
        static let topScrimHeight: CGFloat = 200
        static let seamFadeHeight: CGFloat = 120
        #else
        static let textSpacing: CGFloat = 8
        static let logoFetchHeight = 160
        static let backdropFetchWidth = 1600
        static let logoWidth: CGFloat = 240
        static let logoHeight: CGFloat = 64
        static let titleFont: Font = .title.weight(.bold)
        static let subtitleFont: Font = .subheadline.weight(.medium)
        static let actionsTopPadding: CGFloat = 4
        static let inset: CGFloat = 20
        static let bottomInset: CGFloat = 28
        static let cornerRadius: CGFloat = 14
        static let horizontalMargin: CGFloat = 20
        #endif
    }

    private var bannerTitle: String {
        item.type == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
    }

    private var bannerSubtitle: String? {
        if item.type == .episode {
            return [item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · ")
        }
        return item.genres?.prefix(3).joined(separator: " · ")
    }
}

#if os(tvOS)
/// Hero pill that draws its own focus: white and lifted when focused, a
/// translucent capsule otherwise, so the focused control is obvious across a
/// room. `compact` makes a round icon button.
struct TVPillButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    @Environment(\.isFocused) private var focusEngineFocused

    /// -HomeFocusPreview 1 paints the prominent pill focused, so the shot
    /// harness can photograph the focus state without a remote to move it.
    private var isFocused: Bool {
        #if DEBUG
        if prominent, UserDefaults.standard.bool(forKey: "HomeFocusPreview") { return true }
        #endif
        return focusEngineFocused
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, compact ? 18 : 32)
            .padding(.vertical, 18)
            // Resting pills are all translucent grey, so the one solid white
            // pill is unambiguously the focused one; the lift (scale + drop
            // shadow) is the tvOS focus idiom and reads even against a bright
            // backdrop.
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(background, in: Capsule())
            .scaleEffect(isFocused ? 1.14 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 26, y: 14)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var background: Color {
        if isFocused { return .white }
        return prominent ? .white.opacity(0.32) : .white.opacity(0.2)
    }
}
#endif
