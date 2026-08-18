import SwiftUI
import Observation

/// Live TV tab: Xfinity-style guide (default) with a channel-list alternative.
/// Playback goes through PlayerCoordinator.playChannel → Tuner's stream logic.
@MainActor
@Observable
final class LiveTVModel {
    private(set) var channels: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    var searchTerm = ""

    func load(client: JellyfinClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let items = try await client.liveTvChannels()
            channels = items.sorted { a, b in
                let aFav = a.userData?.isFavorite == true
                let bFav = b.userData?.isFavorite == true
                if aFav != bFav { return aFav }
                let aNum = Double(a.displayChannelNumber ?? "") ?? .greatestFiniteMagnitude
                let bNum = Double(b.displayChannelNumber ?? "") ?? .greatestFiniteMagnitude
                if aNum != bNum { return aNum < bNum }
                return (a.name ?? "") < (b.name ?? "")
            }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var filtered: [BaseItem] {
        let term = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return channels }
        return channels.filter { channel in
            if channel.displayTitle.lowercased().contains(term) { return true }
            if channel.displayChannelNumber?.contains(term) == true { return true }
            if let program = channel.currentProgram?.value.name?.lowercased(), program.contains(term) {
                return true
            }
            return false
        }
    }
}

struct LiveTVView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case guide, channels
        var id: String { rawValue }
        var label: String { self == .guide ? "Guide" : "Channels" }
        var icon: String { self == .guide ? "rectangle.grid.1x2" : "list.bullet" }
    }

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var model = LiveTVModel()
    @State private var mode: Mode = .guide

    var body: some View {
        Group {
            switch mode {
            case .guide:
                GuideView()
            case .channels:
                channelListBody
            }
        }
        .navigationTitle("Live TV")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder
    private var channelListBody: some View {
        Group {
            if let error = model.errorMessage, !model.hasLoaded {
                ErrorRetryView(message: error) {
                    Task { await reload() }
                }
            } else if !model.hasLoaded {
                CenteredProgressView()
            } else {
                channelList
            }
        }
        .searchable(text: $model.searchTerm, prompt: "Channel or program")
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.load(client: client)
    }

    private var channelList: some View {
        List(model.filtered) { channel in
            ChannelListRow(channel: channel) {
                guard let client = app.client else { return }
                player.playChannel(channel, client: client, settings: app.settings)
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.hasLoaded, model.filtered.isEmpty {
                ContentUnavailableView(
                    model.channels.isEmpty ? "No channels" : "No matches",
                    systemImage: "tv",
                    description: Text(model.channels.isEmpty
                        ? "This server has no Live TV channels."
                        : "No channel or program matches the search."))
            }
        }
    }
}

struct ChannelListRow: View {
    let channel: BaseItem
    let play: () -> Void

    @Environment(AppState.self) private var app

    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                if app.settings.showChannelNumbers {
                    Text(channel.displayChannelNumber ?? "")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                    RemoteImage(
                        url: app.client?.imageURL(
                            itemId: channel.id, type: .primary,
                            tag: channel.imageTags?["Primary"], maxHeight: 120),
                        contentMode: .fit)
                    .padding(6)
                }
                .frame(width: 88, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(channel.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if channel.userData?.isFavorite == true {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    if let program = channel.currentProgram?.value {
                        Text(programLine(program))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = channel.currentProgramProgress {
                            ProgressBar(fraction: progress)
                                .frame(maxWidth: 220)
                                .clipShape(Capsule())
                        }
                    } else {
                        Text(" ")
                            .font(.caption)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func programLine(_ program: BaseItem) -> String {
        var line = program.name ?? ""
        if let start = program.startDate, let end = program.endDate {
            line += "  ·  \(GuideTime.label(for: start, style: .exact))–\(GuideTime.label(for: end, style: .exact))"
        }
        return line
    }
}
