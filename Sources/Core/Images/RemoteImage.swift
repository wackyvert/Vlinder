import SwiftUI

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
typealias PlatformFontWeight = NSFont.Weight
#else
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
typealias PlatformFontWeight = UIFont.Weight
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Small image loader: decoded images in an NSCache, bytes in a sizable URLCache.
/// Jellyfin image URLs carry the tag as a cache-buster, so plain URL keying is safe.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 600
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async throws -> PlatformImage {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let (data, _) = try await session.data(from: url)
        guard let image = PlatformImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// AsyncImage replacement backed by ImageLoader, with a quiet placeholder.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: PlatformImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        // Seed from the cache synchronously. `.task` does not run inside an
        // ImageRenderer pass, so a screenshot would otherwise draw the
        // placeholder over every logo it already has in memory.
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageLoader.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            image = try? await ImageLoader.shared.load(url)
        }
    }
}
