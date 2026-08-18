import SwiftUI

/// Backdrop hero + logo/title + metadata line, shared by movie/episode/series details
/// (Fladder's DetailScaffold + OverviewHeader, reduced).
struct DetailHeader: View {
    let item: BaseItem
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: app.client?.imageURL(item.backdropRef, maxWidth: 1600))
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(maxHeight: 420)
                .clipped()
            LinearGradient(
                colors: [.clear, .clear, Color.black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                if let logoURL = app.client?.imageURL(item.logoRef, maxHeight: 220) {
                    RemoteImage(url: logoURL, contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 96, alignment: .leading)
                } else {
                    Text(item.displayTitle)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                MetadataLine(item: item)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(20)
        }
    }
}

/// "2023 · 1h 45m · PG-13 · ★ 7.8" strip.
struct MetadataLine: View {
    let item: BaseItem

    private var parts: [String] {
        var parts: [String] = []
        if let label = item.episodeLabel, let series = item.seriesName {
            parts.append("\(series) · \(label)")
        }
        if let year = item.yearLabel { parts.append(year) }
        if let runtime = item.runtimeLabel { parts.append(runtime) }
        if let rating = item.officialRating { parts.append(rating) }
        if let community = item.communityRating {
            parts.append("★ " + String(format: "%.1f", community))
        }
        return parts
    }

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
    }
}

/// Play/resume + favorite + watched controls.
struct PlayControls: View {
    let item: BaseItem
    /// Item actually sent to the player (series play → next-up episode).
    var playTarget: BaseItem? = nil
    /// Queue for auto-advance (season episodes).
    var queue: [BaseItem] = []
    /// Pre-play selections from TrackSelectionRow.
    var mediaSourceId: String? = nil
    var audioStreamIndex: Int? = nil
    var subtitleStreamIndex: Int? = nil
    var onUserDataChanged: (() -> Void)? = nil

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var isBusy = false

    private var target: BaseItem? { playTarget ?? (item.isPlayable ? item : nil) }

    var body: some View {
        HStack(spacing: 12) {
            if let target {
                playButton(for: target)
            }
            favoriteButton
            watchedButton
            Spacer()
        }
    }

    private func playButton(for target: BaseItem) -> some View {
        Button {
            start(target: target, fromBeginning: false)
        } label: {
            Label(playLabel(for: target), systemImage: "play.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .contextMenu {
            if target.resumeTicks != nil {
                Button("Play from beginning") {
                    start(target: target, fromBeginning: true)
                }
            }
        }
    }

    private func playLabel(for target: BaseItem) -> String {
        if let ticks = target.resumeTicks {
            let remaining = (target.runTime ?? 0) - TimeInterval(ticks) / 10_000_000
            if remaining > 60 {
                return "Resume · \(Int(remaining / 60)) min left"
            }
            return "Resume"
        }
        if target.id != item.id, let label = target.episodeLabel {
            return "Play \(label)"
        }
        return "Play"
    }

    private func start(target: BaseItem, fromBeginning: Bool) {
        guard let client = app.client else { return }
        // Subtitle -1 means the user explicitly chose Off; don't send an index.
        let subtitle = (subtitleStreamIndex ?? -1) >= 0 ? subtitleStreamIndex : nil
        player.play(
            item: target,
            queue: queue,
            fromBeginning: fromBeginning,
            audioStreamIndex: target.id == item.id ? audioStreamIndex : nil,
            subtitleStreamIndex: target.id == item.id ? subtitle : nil,
            mediaSourceId: target.id == item.id ? mediaSourceId : nil,
            client: client,
            settings: app.settings)
    }

    private var favoriteButton: some View {
        Button {
            toggle(favorite: !(item.userData?.isFavorite ?? false))
        } label: {
            Image(systemName: item.userData?.isFavorite == true ? "heart.fill" : "heart")
                .foregroundStyle(item.userData?.isFavorite == true ? .red : .primary)
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .help("Favorite")
    }

    private var watchedButton: some View {
        Button {
            toggle(played: !(item.userData?.played ?? false))
        } label: {
            Image(systemName: item.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(item.userData?.played == true ? .blue : .primary)
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .help("Mark watched")
    }

    private func toggle(favorite: Bool? = nil, played: Bool? = nil) {
        guard let client = app.client else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            if let favorite { try? await client.setFavorite(itemId: item.id, favorite: favorite) }
            if let played { try? await client.setPlayed(itemId: item.id, played: played) }
            onUserDataChanged?()
        }
    }
}

/// Horizontal cast strip with circular portraits.
struct PeopleRow: View {
    let people: [ItemPerson]
    @Environment(AppState.self) private var app

    var body: some View {
        if people.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(people) { person in
                            VStack(spacing: 6) {
                                RemoteImage(url: app.client?.imageURL(
                                    itemId: person.id, type: .primary,
                                    tag: person.primaryImageTag, maxWidth: 200))
                                    .frame(width: 76, height: 76)
                                    .clipShape(Circle())
                                Text(person.name ?? "")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(person.role ?? person.type ?? " ")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 88)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

/// "1080p · HEVC · EAC3 5.1" technical summary from the default media source.
struct MediaInfoLine: View {
    let item: BaseItem

    private var summary: String? {
        let streams = item.mediaSources?.first?.mediaStreams ?? item.mediaStreams
        guard let streams, !streams.isEmpty else { return nil }
        var parts: [String] = []
        if let video = streams.first(where: { $0.type == "Video" }) {
            if let height = video.height {
                parts.append(height >= 2000 ? "4K" : "\(height)p")
            }
            if let codec = video.codec { parts.append(codec.uppercased()) }
            if let range = video.videoRange, range != "SDR" { parts.append(range) }
        }
        if let audio = streams.first(where: { $0.type == "Audio" }) {
            var chunk = audio.codec?.uppercased() ?? ""
            if let layout = audio.channelLayout { chunk += " \(layout)" }
            if !chunk.isEmpty { parts.append(chunk) }
        }
        let subCount = streams.filter { $0.type == "Subtitle" }.count
        if subCount > 0 { parts.append("\(subCount) subtitle\(subCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        if let summary {
            Label(summary, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct OverviewText: View {
    let item: BaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tagline = item.taglines?.first {
                Text(tagline)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
            }
            if let genres = item.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
