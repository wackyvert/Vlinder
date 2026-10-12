import Foundation

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum PosterScale: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var factor: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.25
        }
    }
    var smaller: PosterScale? {
        switch self {
        case .large: .medium
        case .medium: .small
        case .small: nil
        }
    }
    var larger: PosterScale? {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: nil
        }
    }
}

enum LibraryViewMode: String, Codable, CaseIterable, Identifiable {
    case grid, atrium
    var id: String { rawValue }
    var label: String {
        switch self {
        case .grid: "Grid"
        case .atrium: "Atrium"
        }
    }
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .atrium: "square.3.layers.3d"
        }
    }
}

/// Client-side settings, persisted as JSON in UserDefaults.
/// Hand-written `init(from:)` with `decodeIfPresent` on every key so adding a
/// setting never resets existing ones (Tuner pattern).
struct AppSettings: Codable, Equatable {
    /// Streaming quality ceiling, passed as MaxStreamingBitrate (bps).
    var maxStreamingBitrate: Int = 120_000_000
    /// Show channel numbers in the Live TV list and guide.
    var showChannelNumbers: Bool = true
    /// Seconds between playback progress reports.
    var progressReportInterval: Double = 10
    /// External lineup URL (M3U or lineup JSON) used to group the TV guide.
    var lineupUrl: String = ""
    /// Guide groups the user has collapsed.
    var collapsedGroups: [String] = []
    var theme: ThemeMode = .system
    var posterScale: PosterScale = .medium
    /// Library browsing presentation (poster grid or the Atrium spatial gallery).
    var libraryViewMode: LibraryViewMode = .grid
    /// Hero banner on the home screen.
    var showHomeBanner: Bool = true
    var appLockEnabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxStreamingBitrate = try container.decodeIfPresent(Int.self, forKey: .maxStreamingBitrate) ?? 120_000_000
        showChannelNumbers = try container.decodeIfPresent(Bool.self, forKey: .showChannelNumbers) ?? true
        progressReportInterval = try container.decodeIfPresent(Double.self, forKey: .progressReportInterval) ?? 10
        lineupUrl = try container.decodeIfPresent(String.self, forKey: .lineupUrl) ?? ""
        collapsedGroups = try container.decodeIfPresent([String].self, forKey: .collapsedGroups) ?? []
        theme = try container.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        posterScale = try container.decodeIfPresent(PosterScale.self, forKey: .posterScale) ?? .medium
        libraryViewMode = try container.decodeIfPresent(LibraryViewMode.self, forKey: .libraryViewMode) ?? .grid
        showHomeBanner = try container.decodeIfPresent(Bool.self, forKey: .showHomeBanner) ?? true
        appLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .appLockEnabled) ?? false
    }

    static let qualityOptions: [(label: String, bitrate: Int)] = [
        ("Auto (120 Mbps)", 120_000_000),
        ("4K (80 Mbps)", 80_000_000),
        ("1080p (20 Mbps)", 20_000_000),
        ("1080p (10 Mbps)", 10_000_000),
        ("720p (8 Mbps)", 8_000_000),
        ("720p (4 Mbps)", 4_000_000),
        ("480p (3 Mbps)", 3_000_000),
        ("360p (1.5 Mbps)", 1_500_000),
    ]

    private static let defaultsKey = "vlinder.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
