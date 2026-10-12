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
        /// The wall: channels wrapped around the viewer, a band per group.
        case atrium

        var id: String { rawValue }

        var label: String {
            switch self {
            case .guide: "Guide"
            case .channels: "Channels"
            case .atrium: "Atrium"
            }
        }

        var icon: String {
            switch self {
            case .guide: "rectangle.grid.1x2"
            case .channels: "list.bullet"
            case .atrium: "square.3.layers.3d"
            }
        }
    }

    @Environment(AppState.self) private var app
    @Environment(PlayerCoordinator.self) private var player
    @State private var model = LiveTVModel()
    @State private var mode: Mode = Self.initialMode

    private static var initialMode: Mode {
        #if DEBUG
        #if !os(tvOS)
        if LiveWallAutopilot.isActive { return .atrium }
        #endif
        if GuideAutopilot.isActive { return .guide }
        #endif
        return .guide
    }

    var body: some View {
        Group {
            switch mode {
            case .guide:
                guideView
            case .channels:
                channelListBody
            case .atrium:
                #if os(tvOS)
                guideView
                #else
                LiveWallView()
                    .ignoresSafeArea(edges: .bottom)
                #endif
            }
        }
        #if os(tvOS)
        // The tab bar already says "Live TV"; the stack's own title is a
        // second copy, set large, that costs the guide two rows of channels.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Live TV")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
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
        #endif
    }

    /// tvOS draws no navigation bar, so a toolbar item there is a control that
    /// exists and cannot be reached — the round-0 frame had no switch at all.
    /// The guide's header strip hosts it instead, after the pager, where the
    /// remote reaches it by pressing right along the strip.
    @ViewBuilder
    private var guideView: some View {
        #if os(tvOS)
        GuideView(headerAccessory: AnyView(GuideModeSwitch(selection: $mode)))
        #else
        GuideView()
        #endif
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

#if os(tvOS)
/// The Guide/Channels switch as the header strip draws it: two segments in the
/// day pill's own cloth, the chosen one lit, each a guide button so focus is
/// the same ring the rest of the strip wears. Not `Picker(.segmented)`: tvOS's
/// segmented control is a platform-styled glass slab that answered focus with
/// the same white halo the day pill was faulted for.
///
/// The chosen segment is lit grey, not white: the focus ring is white, and on
/// a white segment it vanished — the one control in the strip whose focus
/// could not be seen was the one that had just been selected.
struct GuideModeSwitch: View {
    @Binding var selection: LiveTVView.Mode
    @FocusState private var focused: LiveTVView.Mode?

    private static let radius = GuideMetrics.scaled(8)
    /// Two steps above the pill: lit enough to read as chosen from the sofa,
    /// dark enough that a white ring on it is unmistakable.
    private static let lit = Color(hex: 0x4A4C56)

    var body: some View {
        HStack(spacing: GuideMetrics.scaled(4)) {
            ForEach(LiveTVView.Mode.allCases.filter { $0 != .atrium }) { mode in
                Button { selection = mode } label: {
                    Text(mode.label)
                        .font(.system(size: GuideMetrics.headerType(17), weight: .medium))
                        .foregroundStyle(.white.opacity(selection == mode ? 1 : 0.7))
                        .padding(.horizontal, GuideMetrics.scaled(14))
                        .frame(height: GuideMetrics.headerStripHeight)
                        .background(
                            selection == mode ? Self.lit : GuidePalette.pill,
                            in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                }
                .guideButtonStyle(cornerRadius: Self.radius)
                .focused($focused, equals: mode)
            }
        }
        .task {
            #if DEBUG
            // -GuideFocus mode: photograph the switch focused. The round-1
            // sheet shows this frame with nothing focused at all: one request
            // at 400 ms landed while the guide's `defaultFocus` was still
            // claiming the airing-now cell, and lost. So the request is made
            // late and then repeated until the engine reports it took.
            guard case .modeSwitch? = GuideAutopilot.focusTarget else { return }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(600))
                if focused == selection { return }
                focused = selection
            }
            #endif
        }
    }
}
#endif
