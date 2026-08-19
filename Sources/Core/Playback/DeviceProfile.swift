import Foundation

// Ported from Tuner's JellyfinDeviceProfile — proven against Jake's server; do not
// "improve" the live-TV-relevant parts without testing there first.
// Direct play covers what AVFoundation handles natively; everything else transcodes
// to HLS with TS segments. Subtitle profiles are a Vlinder addition for VOD: they
// let the server deliver text subs as HLS-segmented WebVTT that AVPlayer surfaces
// in its native subtitle menu (no effect on live TV).

struct DeviceProfile: Encodable {
    var maxStreamingBitrate: Int = 120_000_000
    var directPlayProfiles: [DirectPlayProfile] = []
    var transcodingProfiles: [TranscodingProfile] = []
    var subtitleProfiles: [SubtitleProfile] = []
    var codecProfiles: [CodecProfile] = []

    enum CodingKeys: String, CodingKey {
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
        case codecProfiles = "CodecProfiles"
    }

    /// Tuner's live TV profile, byte-for-byte (JFDeviceProfile.tuner there).
    static let live = DeviceProfile(
        maxStreamingBitrate: 120_000_000,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mp4,m4v,mov,ts,mpegts",
                type: "Video",
                videoCodec: "h264,hevc",
                audioCodec: "aac,ac3,eac3"
            )
        ],
        transcodingProfiles: [
            TranscodingProfile(
                container: "ts",
                type: "Video",
                videoCodec: "h264,hevc",
                audioCodec: "aac,ac3,eac3",
                streamProtocol: "hls",
                context: "Streaming",
                maxAudioChannels: "6",
                minSegments: 1,
                breakOnNonKeyFrames: true
            )
        ],
        subtitleProfiles: [],
        codecProfiles: [])

    /// VOD profile. Transcoding targets fMP4 HLS, not TS: Apple's HLS stack
    /// requires fragmented-MP4 segments for HEVC — an HEVC remux into TS
    /// "plays" with the video track silently dropped (audio-only glyph).
    /// fMP4 lets the server remux HEVC MKVs without re-encoding. Raw TS is
    /// also excluded from direct play here (endless-TS AVPlayer hazard).
    static let vod = DeviceProfile(
        maxStreamingBitrate: 120_000_000,
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mp4,m4v,mov",
                type: "Video",
                videoCodec: "h264,hevc",
                audioCodec: "aac,ac3,eac3"
            ),
            DirectPlayProfile(container: "mp3", type: "Audio", videoCodec: nil, audioCodec: "mp3"),
            DirectPlayProfile(container: "m4a,m4b", type: "Audio", videoCodec: nil, audioCodec: "aac,alac"),
            DirectPlayProfile(container: "flac", type: "Audio", videoCodec: nil, audioCodec: "flac"),
        ],
        transcodingProfiles: [
            TranscodingProfile(
                container: "mp4",
                type: "Video",
                videoCodec: "h264,hevc",
                audioCodec: "aac,ac3,eac3",
                streamProtocol: "hls",
                context: "Streaming",
                maxAudioChannels: "6",
                minSegments: 1,
                breakOnNonKeyFrames: true
            ),
            TranscodingProfile(
                container: "mp3",
                type: "Audio",
                videoCodec: nil,
                audioCodec: "mp3",
                streamProtocol: "http",
                context: "Streaming",
                maxAudioChannels: nil,
                minSegments: nil,
                breakOnNonKeyFrames: nil
            ),
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "vtt", method: "External"),
        ],
        codecProfiles: [])
}

struct DirectPlayProfile: Encodable {
    var container: String
    var type: String
    var videoCodec: String?
    var audioCodec: String?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
    }
}

struct TranscodingProfile: Encodable {
    var container: String
    var type: String
    var videoCodec: String?
    var audioCodec: String?
    /// Encoded as "Protocol" — a Swift keyword, hence the property name.
    var streamProtocol: String
    var context: String
    var maxAudioChannels: String?
    var minSegments: Int?
    var breakOnNonKeyFrames: Bool?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case streamProtocol = "Protocol"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
    }
}

struct SubtitleProfile: Encodable {
    var format: String
    var method: String

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}

struct CodecProfile: Encodable {
    var type: String?
    var codec: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
    }
}

// MARK: - Playback request/report bodies

struct PlaybackInfoBody: Encodable {
    var deviceProfile: DeviceProfile
    var enableDirectPlay: Bool = true
    var enableDirectStream: Bool = true
    var enableTranscoding: Bool = true
    var autoOpenLiveStream: Bool = false
    /// nil for live TV — Tuner's proven body sends exactly five keys there.
    var isPlayback: Bool?
    var startTimeTicks: Int64?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var mediaSourceId: String?
    var maxStreamingBitrate: Int?

    enum CodingKeys: String, CodingKey {
        case deviceProfile = "DeviceProfile"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case isPlayback = "IsPlayback"
        case startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case mediaSourceId = "MediaSourceId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
    }
}

struct PlaybackStartBody: Encodable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var liveStreamId: String?
    var canSeek: Bool
    var playMethod: String
    var positionTicks: Int64?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case liveStreamId = "LiveStreamId"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case positionTicks = "PositionTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

struct PlaybackProgressBody: Encodable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var liveStreamId: String?
    var positionTicks: Int64
    var isPaused: Bool
    var playMethod: String

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case liveStreamId = "LiveStreamId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
    }
}

struct PlaybackStopBody: Encodable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var liveStreamId: String?
    var positionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case liveStreamId = "LiveStreamId"
        case positionTicks = "PositionTicks"
    }
}

struct ProgramsRequestBody: Encodable {
    /// nil = all channels (the guide's paged bulk fetch).
    var channelIds: [String]?
    var minEndDate: Date
    var maxStartDate: Date
    var startIndex: Int?
    var limit: Int?
    var sortBy: [String] = ["StartDate"]
    var enableImages: Bool = false
    var enableUserData: Bool = false
    var fields: [String] = ["Overview"]

    enum CodingKeys: String, CodingKey {
        case channelIds = "ChannelIds"
        case minEndDate = "MinEndDate"
        case maxStartDate = "MaxStartDate"
        case startIndex = "StartIndex"
        case limit = "Limit"
        case sortBy = "SortBy"
        case enableImages = "EnableImages"
        case enableUserData = "EnableUserData"
        case fields = "Fields"
    }
}
