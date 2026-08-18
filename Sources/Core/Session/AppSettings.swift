import Foundation

/// Client-side settings, persisted as JSON in UserDefaults.
/// Hand-written `init(from:)` with `decodeIfPresent` on every key so adding a
/// setting never resets existing ones (Tuner pattern).
struct AppSettings: Codable, Equatable {
    /// Streaming quality ceiling, passed as MaxStreamingBitrate (bps).
    var maxStreamingBitrate: Int = 120_000_000
    /// Show channel numbers in the Live TV list.
    var showChannelNumbers: Bool = true
    /// Seconds of progress-report interval during playback.
    var progressReportInterval: Double = 10

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxStreamingBitrate = try container.decodeIfPresent(Int.self, forKey: .maxStreamingBitrate) ?? 120_000_000
        showChannelNumbers = try container.decodeIfPresent(Bool.self, forKey: .showChannelNumbers) ?? true
        progressReportInterval = try container.decodeIfPresent(Double.self, forKey: .progressReportInterval) ?? 10
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
