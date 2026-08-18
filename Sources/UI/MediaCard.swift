import SwiftUI

/// Poster / thumb card used across rows and grids. Tapping navigates to the
/// item's detail screen (each tab's stack registers BaseItem as a destination).
struct MediaCard: View {
    enum Style {
        case poster // 2:3
        case thumb  // 16:9 still/backdrop

        var aspectRatio: CGFloat {
            switch self {
            case .poster: 2.0 / 3.0
            case .thumb: 16.0 / 9.0
            }
        }
    }

    let item: BaseItem
    var style: Style = .poster
    var width: CGFloat = 140
    var showsTitle = true

    @Environment(AppState.self) private var app

    private var height: CGFloat { width / style.aspectRatio }

    private var imageRef: ImageRef? {
        style == .poster ? item.posterRef : item.thumbRef
    }

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                if showsTitle {
                    titleBlock
                }
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        RemoteImage(url: app.client?.imageURL(imageRef, maxWidth: Int(width * 2)))
            .frame(width: width, height: height)
            .clipped()
            .overlay(alignment: .bottom) {
                if let progress = item.progressFraction {
                    ProgressBar(fraction: progress)
                }
            }
            .overlay(alignment: .topTrailing) {
                statusBadge
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let count = item.userData?.unplayedItemCount, count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.blue, in: Capsule())
                .padding(6)
        } else if item.userData?.played == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.white, .blue)
                .padding(6)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.posterSubtitle ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.45))
                Rectangle()
                    .fill(.blue)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

/// Live TV channel card for the home screen's "On Now" row.
struct ChannelCard: View {
    let channel: BaseItem
    var width: CGFloat = 200

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        Button {
            guard let client = app.client else { return }
            player.playChannel(channel, client: client, settings: app.settings)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    RemoteImage(
                        url: app.client?.imageURL(
                            itemId: channel.id, type: .primary,
                            tag: channel.imageTags?["Primary"], maxHeight: 200),
                        contentMode: .fit)
                    .padding(12)
                }
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress = channel.currentProgramProgress {
                        ProgressBar(fraction: progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(channel.currentProgram?.value.name ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}
