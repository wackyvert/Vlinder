import SwiftUI

/// Pre-play version / audio / subtitle pickers (Fladder's MediaStreamHelper).
/// Selections flow into PlaybackInfo so the server remuxes accordingly.
struct TrackSelectionRow: View {
    let item: BaseItem
    @Binding var selectedSourceId: String?
    @Binding var audioIndex: Int?
    @Binding var subtitleIndex: Int?

    private var sources: [MediaSource] { item.mediaSources ?? [] }

    private var selectedSource: MediaSource? {
        sources.first { $0.id == selectedSourceId } ?? sources.first
    }

    private var audioStreams: [MediaStream] {
        (selectedSource?.mediaStreams ?? item.mediaStreams ?? []).filter { $0.type == "Audio" }
    }

    private var subtitleStreams: [MediaStream] {
        (selectedSource?.mediaStreams ?? item.mediaStreams ?? []).filter { $0.type == "Subtitle" }
    }

    var body: some View {
        let showVersion = sources.count > 1
        let showAudio = audioStreams.count > 1
        let showSubtitles = !subtitleStreams.isEmpty
        if showVersion || showAudio || showSubtitles {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { pickers(showVersion, showAudio, showSubtitles) }
                VStack(alignment: .leading, spacing: 8) { pickers(showVersion, showAudio, showSubtitles) }
            }
        }
    }

    @ViewBuilder
    private func pickers(_ showVersion: Bool, _ showAudio: Bool, _ showSubtitles: Bool) -> some View {
        if showVersion {
            Menu {
                ForEach(sources) { source in
                    Button {
                        selectedSourceId = source.id
                        audioIndex = nil
                        subtitleIndex = nil
                    } label: {
                        if source.id == selectedSource?.id {
                            Label(sourceLabel(source), systemImage: "checkmark")
                        } else {
                            Text(sourceLabel(source))
                        }
                    }
                }
            } label: {
                pickerChip(icon: "film.stack", text: sourceLabel(selectedSource))
            }
        }
        if showAudio {
            Menu {
                ForEach(audioStreams, id: \.index) { stream in
                    Button {
                        audioIndex = stream.index
                    } label: {
                        if isSelectedAudio(stream) {
                            Label(streamLabel(stream), systemImage: "checkmark")
                        } else {
                            Text(streamLabel(stream))
                        }
                    }
                }
            } label: {
                pickerChip(icon: "waveform", text: selectedAudioLabel)
            }
        }
        if showSubtitles {
            Menu {
                Button {
                    subtitleIndex = -1
                } label: {
                    if subtitleIndex == -1 {
                        Label("Off", systemImage: "checkmark")
                    } else {
                        Text("Off")
                    }
                }
                ForEach(subtitleStreams, id: \.index) { stream in
                    Button {
                        subtitleIndex = stream.index
                    } label: {
                        if subtitleIndex == stream.index {
                            Label(streamLabel(stream), systemImage: "checkmark")
                        } else {
                            Text(streamLabel(stream))
                        }
                    }
                }
            } label: {
                pickerChip(icon: "captions.bubble", text: selectedSubtitleLabel)
            }
        }
    }

    private func pickerChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .foregroundStyle(.primary)
    }

    private func sourceLabel(_ source: MediaSource?) -> String {
        guard let source else { return "Version" }
        if let name = source.name, !name.isEmpty { return name }
        if let height = source.mediaStreams?.first(where: { $0.type == "Video" })?.height {
            return "\(height)p"
        }
        return source.container?.uppercased() ?? "Version"
    }

    private func streamLabel(_ stream: MediaStream) -> String {
        stream.displayTitle ?? stream.title ?? stream.language ?? stream.codec?.uppercased() ?? "Track"
    }

    private func isSelectedAudio(_ stream: MediaStream) -> Bool {
        if let audioIndex { return stream.index == audioIndex }
        return stream.index == selectedSource?.defaultAudioStreamIndex
    }

    private var selectedAudioLabel: String {
        if let audioIndex, let stream = audioStreams.first(where: { $0.index == audioIndex }) {
            return streamLabel(stream)
        }
        if let defaultIndex = selectedSource?.defaultAudioStreamIndex,
           let stream = audioStreams.first(where: { $0.index == defaultIndex }) {
            return streamLabel(stream)
        }
        return audioStreams.first.map(streamLabel) ?? "Audio"
    }

    private var selectedSubtitleLabel: String {
        guard let subtitleIndex, subtitleIndex >= 0 else { return "Subtitles: Off" }
        if let stream = subtitleStreams.first(where: { $0.index == subtitleIndex }) {
            return streamLabel(stream)
        }
        return "Subtitles"
    }
}

/// Chapter thumbnails; tapping plays from the chapter position (Fladder's ChapterRow).
struct ChapterRow: View {
    let item: BaseItem
    var queue: [BaseItem] = []

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player

    private var chapters: [ChapterInfo] { item.chapters ?? [] }

    var body: some View {
        if chapters.count > 1 {
            #if os(tvOS)
            TVHomeShelf(title: "Chapters") {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    chapterCard(chapter, index: index)
                }
            }
            #else
            VStack(alignment: .leading, spacing: 10) {
                Text("Chapters")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            chapterCard(chapter, index: index)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            #endif
        }
    }

    #if os(tvOS)
    private let stillWidth: CGFloat = 320
    private let stillHeight: CGFloat = 180
    private let stillRadius: CGFloat = TVHome.cardCornerRadius
    #else
    private let stillWidth: CGFloat = 168
    private let stillHeight: CGFloat = 94
    private let stillRadius: CGFloat = 8
    #endif

    private func chapterCard(_ chapter: ChapterInfo, index: Int) -> some View {
        #if os(tvOS)
        // Still inside the card button so focus lifts it; caption stays put.
        VStack(alignment: .leading, spacing: 10) {
            Button { playChapter(chapter) } label: { still(chapter, index: index) }
                .buttonStyle(.card)
            chapterCaption(chapter, index: index)
                .padding(.horizontal, 4)
        }
        .frame(width: stillWidth)
        #else
        Button { playChapter(chapter) } label: {
            VStack(alignment: .leading, spacing: 5) {
                still(chapter, index: index)
                chapterCaption(chapter, index: index)
            }
            .frame(width: stillWidth)
        }
        .buttonStyle(.plain)
        #endif
    }

    private func still(_ chapter: ChapterInfo, index: Int) -> some View {
        RemoteImage(url: app.client?.chapterImageURL(
            itemId: item.id, index: index, tag: chapter.imageTag))
            .frame(width: stillWidth, height: stillHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: stillRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: stillRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            }
    }

    private func chapterCaption(_ chapter: ChapterInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chapter.name ?? "Chapter \(index + 1)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(timeLabel(chapter.startPosition))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func playChapter(_ chapter: ChapterInfo) {
        guard let client = app.client else { return }
        player.play(
            item: item,
            queue: queue,
            startTicks: chapter.startPositionTicks,
            client: client,
            settings: app.settings)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// External link chips (IMDb, TMDb, …).
struct ExternalLinksRow: View {
    let item: BaseItem

    private var links: [(name: String, url: URL)] {
        (item.externalUrls ?? []).compactMap { external in
            guard let name = external.name, let raw = external.url, let url = URL(string: raw) else {
                return nil
            }
            return (name, url)
        }
    }

    var body: some View {
        #if os(tvOS)
        // No browser on the TV to open IMDb or TMDb in.
        EmptyView()
        #else
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(links, id: \.name) { link in
                        Link(destination: link.url) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption2)
                                Text(link.name)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        #endif
    }
}
