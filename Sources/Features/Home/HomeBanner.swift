import Combine
import SwiftUI

/// Auto-advancing hero carousel over next-up / continue-watching items
/// (Fladder's HomeBannerWidget, "combined" style).
struct HomeBanner: View {
    let items: [BaseItem]

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var index = 0

    private let advanceInterval: TimeInterval = 8

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            banner
                .onReceive(Timer.publish(every: advanceInterval, on: .main, in: .common).autoconnect()) { _ in
                    guard items.count > 1 else { return }
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

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: app.client?.imageURL(item.backdropRef, maxWidth: 1600))
            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                if let logoURL = app.client?.imageURL(item.logoRef, maxHeight: 160) {
                    RemoteImage(url: logoURL, contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 64, alignment: .leading)
                } else {
                    Text(bannerTitle)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let subtitle = bannerSubtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button {
                        guard let client = app.client else { return }
                        player.play(item: item, client: client, settings: app.settings)
                    } label: {
                        Label(item.resumeTicks != nil ? "Resume" : "Play", systemImage: "play.fill")
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
                .padding(.top, 4)
            }
            .padding(20)
            .padding(.bottom, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
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
