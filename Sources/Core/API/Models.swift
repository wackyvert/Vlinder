import Foundation

// Every decoded field is Optional: key presence varies across Jellyfin 10.8-10.11.
// Explicit PascalCase CodingKeys throughout — see JellyfinJSON for why.

// MARK: - Server & authentication

struct PublicServerInfo: Codable {
    var serverName: String?
    var version: String?
    var id: String?
    var productName: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
        case productName = "ProductName"
    }
}

struct AuthenticationResult: Codable {
    var user: JellyfinUser?
    var accessToken: String?
    var serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

struct JellyfinUser: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct QuickConnectResult: Codable {
    var authenticated: Bool?
    var secret: String?
    var code: String?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
    }
}

// MARK: - Items

enum ItemType: String, Codable, Hashable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case userView = "UserView"
    case tvChannel = "TvChannel"
    case tvProgram = "TvProgram"
    case liveTvChannel = "LiveTvChannel"
    case audio = "Audio"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case photo = "Photo"
    case photoAlbum = "PhotoAlbum"
    case video = "Video"
    case trailer = "Trailer"
    case person = "Person"
    case genre = "Genre"
    case playlist = "Playlist"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemType(rawValue: raw) ?? .unknown
    }
}

struct BaseItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var originalTitle: String?
    var type: ItemType?
    var collectionType: String?
    var overview: String?
    var taglines: [String]?
    var genres: [String]?

    var parentId: String?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var channelId: String?
    var channelName: String?

    var indexNumber: Int?
    var indexNumberEnd: Int?
    var parentIndexNumber: Int?
    var productionYear: Int?
    var premiereDate: Date?
    var startDate: Date?
    var endDate: Date?
    var status: String?

    var runTimeTicks: Int64?
    var communityRating: Double?
    var criticRating: Double?
    var officialRating: String?

    var childCount: Int?
    var recursiveItemCount: Int?

    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var primaryImageAspectRatio: Double?
    var seriesPrimaryImageTag: String?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?

    var userData: UserItemData?
    var people: [ItemPerson]?
    var studios: [NameGuidPair]?
    var mediaSources: [MediaSource]?
    var mediaStreams: [MediaStream]?
    var chapters: [ChapterInfo]?
    var providerIds: [String: String]?
    var externalUrls: [ExternalURL]?

    // Live TV
    var number: String?
    var channelNumber: String?
    var currentProgram: BaseItemBox?
    var episodeTitle: String?
    var isMovie: Bool?
    var isSports: Bool?
    var isNews: Bool?
    var isKids: Bool?
    var isSeries: Bool?
    var isLive: Bool?

    var isFolder: Bool?
    var mediaType: String?
    var locationType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case type = "Type"
        case collectionType = "CollectionType"
        case overview = "Overview"
        case taglines = "Taglines"
        case genres = "Genres"
        case parentId = "ParentId"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case indexNumber = "IndexNumber"
        case indexNumberEnd = "IndexNumberEnd"
        case parentIndexNumber = "ParentIndexNumber"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case status = "Status"
        case runTimeTicks = "RunTimeTicks"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case officialRating = "OfficialRating"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case userData = "UserData"
        case people = "People"
        case studios = "Studios"
        case mediaSources = "MediaSources"
        case mediaStreams = "MediaStreams"
        case chapters = "Chapters"
        case providerIds = "ProviderIds"
        case externalUrls = "ExternalUrls"
        case number = "Number"
        case channelNumber = "ChannelNumber"
        case currentProgram = "CurrentProgram"
        case episodeTitle = "EpisodeTitle"
        case isMovie = "IsMovie"
        case isSports = "IsSports"
        case isNews = "IsNews"
        case isKids = "IsKids"
        case isSeries = "IsSeries"
        case isLive = "IsLive"
        case isFolder = "IsFolder"
        case mediaType = "MediaType"
        case locationType = "LocationType"
    }

    var runTime: TimeInterval? {
        runTimeTicks.map { TimeInterval($0) / 10_000_000 }
    }
}

/// Boxes a nested `BaseItem` (e.g. a channel's `CurrentProgram`) to break struct recursion.
final class BaseItemBox: Codable, Hashable {
    let value: BaseItem

    init(_ value: BaseItem) { self.value = value }

    required init(from decoder: Decoder) throws {
        value = try BaseItem(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    static func == (lhs: BaseItemBox, rhs: BaseItemBox) -> Bool { lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

struct UserItemData: Codable, Hashable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var played: Bool?
    var playedPercentage: Double?
    var unplayedItemCount: Int?
    var lastPlayedDate: Date?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
        case lastPlayedDate = "LastPlayedDate"
    }

    var playbackPosition: TimeInterval {
        TimeInterval(playbackPositionTicks ?? 0) / 10_000_000
    }
}

struct ItemPerson: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct NameGuidPair: Codable, Identifiable, Hashable {
    var id: String
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct ChapterInfo: Codable, Hashable {
    var startPositionTicks: Int64?
    var name: String?
    var imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    var startPosition: TimeInterval {
        TimeInterval(startPositionTicks ?? 0) / 10_000_000
    }
}

struct ExternalURL: Codable, Hashable {
    var name: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "Url"
    }
}

struct ItemsResult: Codable {
    var items: [BaseItem]?
    var totalRecordCount: Int?
    var startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }
}

// MARK: - Playback

struct PlaybackInfoResponse: Codable {
    var mediaSources: [MediaSource]?
    var playSessionId: String?
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

struct MediaSource: Codable, Identifiable, Hashable {
    var id: String?
    var name: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var transcodingContainer: String?
    var transcodingSubProtocol: String?
    var liveStreamId: String?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var etag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case runTimeTicks = "RunTimeTicks"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case transcodingContainer = "TranscodingContainer"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case liveStreamId = "LiveStreamId"
        case mediaStreams = "MediaStreams"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case etag = "ETag"
    }
}

struct MediaStream: Codable, Hashable {
    var codec: String?
    var language: String?
    var displayTitle: String?
    var title: String?
    var type: String?
    var index: Int?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    var height: Int?
    var width: Int?
    var bitRate: Int?
    var channels: Int?
    var channelLayout: String?
    var videoRange: String?
    var deliveryUrl: String?
    var isTextSubtitleStream: Bool?
    var profile: String?
    var aspectRatio: String?

    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case type = "Type"
        case index = "Index"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case height = "Height"
        case width = "Width"
        case bitRate = "BitRate"
        case channels = "Channels"
        case channelLayout = "ChannelLayout"
        case videoRange = "VideoRange"
        case deliveryUrl = "DeliveryUrl"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case profile = "Profile"
        case aspectRatio = "AspectRatio"
    }
}

// MARK: - Filters

struct FilterValues: Codable {
    var genres: [String]?
    var tags: [String]?
    var officialRatings: [String]?
    var years: [Int]?

    enum CodingKeys: String, CodingKey {
        case genres = "Genres"
        case tags = "Tags"
        case officialRatings = "OfficialRatings"
        case years = "Years"
    }
}
