import SwiftUI

/// The guide's first column: the channel logo, large.
///
/// Deliberately no channel name and no number — the reference frame carries the
/// logo and a favourite star, nothing else, and the logo is the biggest thing
/// in the row. The name and number live in the accessibility label and the
/// tooltip instead of competing with it.
struct GuideChannelCell: View {
    let channel: BaseItem
    let isPlaying: Bool

    @Environment(AppState.self) private var app

    private var logoURL: URL? {
        app.client?.imageURL(
            itemId: channel.id, type: .primary,
            tag: channel.imageTags?["Primary"],
            maxHeight: Int(GuideMetrics.logoMaxSize.height * 3))
    }

    var body: some View {
        #if DEBUG
        let _ = GuideBench.tally("logo")
        #endif
        // Circular, not continuous — though at radius 6 the two rasterise
        // alike here. The reference's corner cuts 13.8px of the cell where
        // ours cuts 8.5: its radius measures nearer 8 than the spec's 6.
        RoundedRectangle(cornerRadius: GuideMetrics.cellCornerRadius)
            .fill(GuidePalette.cell)
            .overlay {
                GuideChannelGlyph(url: logoURL, callSign: callSign)
            }
            .overlay(alignment: .topLeading) {
                if channel.userData?.isFavorite == true {
                    Image(systemName: "star.fill")
                        // 9.5pt is what rasterises to the reference's own 10×10
                        // ink, and the frame pins that ink box: a symbol's
                        // layout box carries bearing the inset would otherwise
                        // inherit, which is how 14 came out as 15/16.
                        .font(.system(size: GuideMetrics.scaled(9.5)))
                        .foregroundStyle(favouriteBlue)
                        .frame(width: GuideMetrics.scaled(10), height: GuideMetrics.scaled(10))
                        // The reference measures 13, where the spec says 14.
                        .padding(GuideMetrics.starInset - GuideMetrics.scaled(1))
                }
            }
            .overlay {
                if isPlaying {
                    RoundedRectangle(cornerRadius: GuideMetrics.cellCornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: GuideMetrics.scaled(2))
                }
            }
            .frame(
                width: GuideMetrics.logoColumnWidth,
                height: GuideMetrics.rowCellHeight)
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        let number = channel.displayChannelNumber
        return number.map { "\($0) · \(channel.displayTitle)" } ?? channel.displayTitle
    }

    /// The channel's own short mark, for a channel with no usable art. Names
    /// arrive as "US: CBS 4 (WCCO) MINNEAPOLIS HD": the bracketed call sign is
    /// the identity, and failing that the words left once the country and
    /// transmission qualifiers are dropped.
    private var callSign: String {
        let name = channel.displayTitle
        if let open = name.firstIndex(of: "("),
           let close = name[open...].firstIndex(of: ")") {
            let sign = name[name.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            if sign.count >= 3 { return sign.uppercased() }
        }
        let qualifiers: Set<String> = ["HD", "SD", "FHD", "UHD", "4K", "H", "US", "CA", "UK"]
        let words = name.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: ": ()"))
            .filter { !$0.isEmpty && !qualifiers.contains($0) }
        return words.prefix(2).joined(separator: " ")
    }
}

/// The reference's favourite blue. The app accent is lighter and more
/// saturated, which reads as a different mark beside the reference's.
private let favouriteBlue = Color(hex: 0x2A55D2)

/// A channel logo drawn the way the reference draws them: one flat white
/// glyph, whatever colours the asset itself is made of.
///
/// Jellyfin channel art is a grab bag — transparent PNGs, JPEGs on a white
/// background, JPEGs that are a solid brand field with the mark knocked out of
/// it. Drawn as they arrive, the column alternates between marks that vanish
/// into the cell (a black wordmark sits at 1.05:1 against it) and opaque
/// letterbox slabs. Masking every asset down to its own silhouette is what
/// makes the column read as one thing instead of six treatments.
private struct GuideChannelGlyph: View {
    let url: URL?
    let callSign: String

    @State private var glyph: PlatformImage?

    init(url: URL?, callSign: String) {
        self.url = url
        self.callSign = callSign
        // Seeded synchronously for the same reason RemoteImage does it: `.task`
        // does not run inside an ImageRenderer pass.
        _glyph = State(initialValue: url.flatMap(GuideGlyphMask.cached))
    }

    var body: some View {
        mark
            .frame(
                maxWidth: GuideMetrics.logoMaxSize.width,
                maxHeight: GuideMetrics.logoMaxSize.height)
            .task(id: url) {
                guard let url else {
                    glyph = nil
                    return
                }
                if let hit = GuideGlyphMask.cached(url) {
                    glyph = hit
                    return
                }
                glyph = try? await GuideGlyphMask.silhouette(of: url)
            }
    }

    @ViewBuilder private var mark: some View {
        if let glyph {
            Image(platformImage: glyph)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // A grey placeholder says nothing about which channel this is, so
            // the call sign stands in as the mark — the same white, at the
            // same weight, as the glyphs beside it.
            Text(callSign)
                .font(.system(size: GuideMetrics.scaled(27), weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(.white)
        }
    }
}

/// Channel art reduced to a white silhouette, once per asset.
///
/// Two stages, because there are two kinds of asset: one with a real alpha
/// channel, where the alpha *is* the mask, and one flattened onto a
/// background, where the background has to be keyed out. Keying by flood fill
/// rather than by colour alone is what keeps a mark whose own strokes are the
/// background's colour: a wordmark knocked out of a brand tile is white, and so
/// is the plate that tile sits on.
private enum GuideGlyphMask {
    private static let cache: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 600
        return cache
    }()

    /// Assets with no silhouette worth shipping, remembered so every row that
    /// scrolls past does not re-walk the same pixels to the same verdict.
    /// Main-actor only: `silhouette(of:)` is nonisolated and thirty rows
    /// scrolling in at once mutate this concurrently otherwise, which crashed
    /// the in-player guide with an unrecognised selector inside Set.insert.
    @MainActor private static var unmaskable: Set<URL> = []

    static func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    static func silhouette(of url: URL) async throws -> PlatformImage? {
        if let hit = cached(url) { return hit }
        if await MainActor.run(body: { unmaskable.contains(url) }) { return nil }
        let art = try await ImageLoader.shared.load(url)
        guard let glyph = silhouette(of: art) else {
            await MainActor.run { _ = unmaskable.insert(url) }
            return nil
        }
        cache.setObject(glyph, forKey: url as NSURL)
        return glyph
    }

    /// Within `edge` of a keyed colour a pixel is background; past `ink` it is
    /// ink; between the two it is an antialiased edge and keeps its partial
    /// coverage, or every letter comes out chewed.
    private static let edge: Float = 0.06
    private static let ink: Float = 0.30

    /// Below this a sealed pocket of background colour is JPEG ringing caught
    /// inside a stroke rather than a counter, and keying it out peppers the
    /// glyph with holes. Pickleball's script seals 76 pockets at the 96px the
    /// server serves: 54 of one or two pixels, then a clean step to the 3-to-25
    /// px ones that are its actual counters.
    private static let pocket = 3

    private static func silhouette(of art: PlatformImage) -> PlatformImage? {
        guard let bitmap = bitmap(of: art) else { return nil }
        let mask = inkMask(of: bitmap)
        guard let bounds = inkBounds(of: mask, in: bitmap),
              carriesAGlyph(mask, of: bitmap, in: bounds)
        else { return nil }
        return white(mask, of: bitmap, in: bounds)
    }

    /// Whether this silhouette is one we can vouch for.
    ///
    /// A mask is only as good as the asset under it, and most of this server's
    /// channel art is a flattened JPEG: some of it is a photograph (a chrome
    /// badge, a paddle-and-ball illustration), some a filled disc with the name
    /// knocked out in the very colour we are about to fill with. Whitened,
    /// those come out as splats and blank circles — the same sloppiness the
    /// white glyph was meant to end — so they go to the call sign instead.
    ///
    /// Measured over the live lineup and the fixture: 47 assets, 7 rejected —
    /// an alpha-channel disc with its name knocked out of it, where there is no
    /// background to key and so nothing to recover; an opaque ticket slab; a
    /// wordmark the server serves cropped mid-letter; a photographed paddle;
    /// and three copies of a chrome plaque. Every threshold sits in a gap that
    /// data leaves.
    private static func carriesAGlyph(
        _ mask: [Float], of bitmap: Bitmap,
        in bounds: (x: Int, y: Int, width: Int, height: Int)
    ) -> Bool {
        var ink = [Bool](repeating: false, count: bounds.width * bounds.height)
        var inkCount = 0
        var covered: Float = 0
        for y in 0..<bounds.height {
            let row = (bounds.y + y) * bitmap.width + bounds.x
            for x in 0..<bounds.width {
                covered += mask[row + x]
                guard mask[row + x] > 0.6 else { continue }
                ink[y * bounds.width + x] = true
                inkCount += 1
            }
        }
        guard inkCount > 0 else { return false }

        // Nothing keyed out: a photograph, or a tile whose background we could
        // not name. Filling that white would put a slab in the column.
        guard covered / Float(bounds.width * bounds.height) < 0.92 else { return false }

        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < bounds.width, y < bounds.height else { return false }
            return ink[y * bounds.width + x]
        }
        var edges = 0
        for y in 0..<bounds.height {
            for x in 0..<bounds.width where isInk(x, y) {
                if !isInk(x - 1, y) || !isInk(x + 1, y)
                    || !isInk(x, y - 1) || !isInk(x, y + 1) {
                    edges += 1
                }
            }
        }

        // Background sealed inside the ink — the counters of the mark.
        var reached = [Bool](repeating: false, count: bounds.width * bounds.height)
        var queue: [Int] = []
        var head = 0

        func reach(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < bounds.width, y < bounds.height, !isInk(x, y)
            else { return }
            let cell = y * bounds.width + x
            guard !reached[cell] else { return }
            reached[cell] = true
            queue.append(cell)
        }

        for x in 0..<bounds.width {
            reach(x, 0)
            reach(x, bounds.height - 1)
        }
        for y in 0..<bounds.height {
            reach(0, y)
            reach(bounds.width - 1, y)
        }
        while head < queue.count {
            let cell = queue[head]
            head += 1
            let x = cell % bounds.width, y = cell / bounds.width
            reach(x - 1, y)
            reach(x + 1, y)
            reach(x, y - 1)
            reach(x, y + 1)
        }
        var sealed = 0
        for y in 0..<bounds.height {
            for x in 0..<bounds.width
            where !isInk(x, y) && !reached[y * bounds.width + x] {
                sealed += 1
            }
        }

        // Type and marks are strokes, so a large share of their ink touches an
        // edge; a featureless disc is 4%. Nearest reject 5% (the PPV ticket),
        // nearest keep 10% (Disney XD).
        //
        // A fat mark can sit under that floor and still read, though, when what
        // is punched out of it is the mark: the Zone discs are 8.5% edge with
        // their own name knocked out, and it is the counters that carry them,
        // not the outline. So counters are the second way through — 7% of the
        // Zone disc's ink against 0.2% of ringing sealed inside the PPV slab.
        let edgeShare = Float(edges) / Float(inkCount)
        let counters = Float(sealed) / Float(inkCount)
        guard edgeShare >= 0.09 || counters >= 0.02 else { return false }

        // One piece with nothing punched out of it is a fragment, not a mark.
        // Every wordmark here is either several pieces or has counters; the
        // ESPN asset — the same logo as ESPN2's, but at 2.3x and cut off on all
        // four sides — is the only thing in 47 that is neither, and it reads as
        // a lattice whichever of its two colours we call the plate.
        guard regions(of: ink, width: bounds.width) > 1 || counters >= 0.02
        else { return false }

        var buckets: [Int: Int] = [:]
        for y in 0..<bounds.height {
            let row = (bounds.y + y) * bitmap.width + bounds.x
            for x in 0..<bounds.width where isInk(x, y) {
                let pixel = (row + x) * 4
                let key = Int(bitmap.rgba[pixel] >> 4) << 8
                    | Int(bitmap.rgba[pixel + 1] >> 4) << 4
                    | Int(bitmap.rgba[pixel + 2] >> 4)
                buckets[key, default: 0] += 1
            }
        }
        let palette = buckets.values.filter { $0 * 100 >= inkCount }.count

        // Busy ink behind soft edges is a photograph. Both halves are needed:
        // the chrome CBC Sport badge and FOX SPORTS' antialiased navy ring both
        // look busy by colour count alone — flat ink with a lot of antialiasing
        // does — and it is their edge share, 24% and 30%, that carries them.
        guard palette < 18 || edgeShare >= 0.20 else { return false }

        // One fused lump, measured as the mark will be drawn rather than as the
        // server stored it: a fat stroke in a 96px asset is a thin one once the
        // asset is fitted into the ceiling. Busy ink is what makes the lump a
        // defect — a fat letterform is fat but flat. Disney XD's XD is a 13pt
        // plateau of five colours and reads; the pickleball paddle is 12pt of
        // thirty-one and is a splat.
        let fit = min(
            GuideMetrics.logoMaxSize.width / CGFloat(bounds.width),
            GuideMetrics.logoMaxSize.height / CGFloat(bounds.height))
        let plateau = Float(fit) * inradius(of: ink, width: bounds.width, height: bounds.height)
        return plateau < 10 || palette < 18
    }

    /// Radius of the largest disc that fits inside the ink, by a 3-4 chamfer
    /// sweep each way — within a few percent of Euclidean for a tenth of the
    /// work of an exact transform.
    private static func inradius(of ink: [Bool], width: Int, height: Int) -> Float {
        var distance = [Int32](repeating: 0, count: ink.count)
        let far = Int32((width + height) * 4)
        for cell in ink.indices where ink[cell] { distance[cell] = far }

        func reach(_ x: Int, _ y: Int) -> Int32 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return distance[y * width + x]
        }
        for y in 0..<height {
            for x in 0..<width where ink[y * width + x] {
                let cell = y * width + x
                distance[cell] = min(
                    distance[cell], reach(x - 1, y - 1) + 4, reach(x, y - 1) + 3,
                    reach(x + 1, y - 1) + 4, reach(x - 1, y) + 3)
            }
        }
        for y in (0..<height).reversed() {
            for x in (0..<width).reversed() where ink[y * width + x] {
                let cell = y * width + x
                distance[cell] = min(
                    distance[cell], reach(x + 1, y + 1) + 4, reach(x, y + 1) + 3,
                    reach(x - 1, y + 1) + 4, reach(x + 1, y) + 3)
            }
        }
        return Float(distance.max() ?? 0) / 3
    }

    /// How many separate pieces the flagged pixels make, 4-connected.
    private static func regions(of flag: [Bool], width: Int) -> Int {
        var walked = [Bool](repeating: false, count: flag.count)
        var count = 0
        for start in flag.indices where flag[start] && !walked[start] {
            count += 1
            walked[start] = true
            var queue = [start]
            var reader = 0
            while reader < queue.count {
                let cell = queue[reader]
                reader += 1
                let x = cell % width
                var next: [Int] = []
                if x > 0 { next.append(cell - 1) }
                if x < width - 1 { next.append(cell + 1) }
                if cell >= width { next.append(cell - width) }
                if cell + width < flag.count { next.append(cell + width) }
                for cell in next where flag[cell] && !walked[cell] {
                    walked[cell] = true
                    queue.append(cell)
                }
            }
        }
        return count
    }

    // MARK: - Masking

    /// A straight-alpha RGBA copy of the asset, capped so the flood fill stays
    /// cheap. Channel art measures 96px square in practice.
    private static func bitmap(of art: PlatformImage) -> Bitmap? {
        #if os(macOS)
        guard let tiff = art.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        #else
        guard let cgImage = art.cgImage else { return nil }
        #endif

        let scale = min(1, 256 / Double(max(cgImage.width, cgImage.height)))
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Un-premultiply, or an antialiased edge pixel reads as a blend
        // towards black and keys out against the wrong colour.
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[pixel + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in pixel..<(pixel + 3) {
                rgba[channel] = UInt8(min(255, Int(rgba[channel]) * 255 / alpha))
            }
        }
        return Bitmap(width: width, height: height, rgba: rgba)
    }

    private static func inkMask(of bitmap: Bitmap) -> [Float] {
        var alpha = [Float](repeating: 0, count: bitmap.width * bitmap.height)
        for pixel in alpha.indices {
            alpha[pixel] = Float(bitmap.rgba[pixel * 4 + 3]) / 255
        }

        // A real alpha channel is already the mask; nothing to guess at.
        let clear = alpha.reduce(into: 0) { count, value in
            if value < 0.12 { count += 1 }
        }
        if clear * 20 >= alpha.count { return alpha }

        // Flattened, so the background has to be named — and white is either
        // the whole plate or part of the mark, never one field among several.
        // Nothing in this lineup seats a white field beside a coloured one,
        // while ESPN and FXM both knock their wordmark out of a full-bleed
        // field and let it run off the edge. So white keys alone when it owns
        // the border, and is ink when it does not: keyed as a co-plate it
        // takes the wordmark with it and leaves the tile behind, and chosen on
        // frame share alone — a quarter of the pixels — it does the same.
        let fields = borderColours(of: bitmap)
        guard let plate = fields.first else { return alpha }
        let keys = plate.isLight ? [.white] : fields.filter { !$0.isLight }
        return keyOut(keys, of: bitmap, alpha: alpha)
    }

    /// Flood the keyed colours out from the border, then out of every pocket
    /// the border cannot reach.
    ///
    /// The second pass is the whole difference between a mark and a splat. Any
    /// mark with a sealed outline encloses background of its own — the bowl of
    /// a script letter, the middle of a ring badge, type knocked out of a tile
    /// — and a border-seeded fill stops at the rim and leaves every one of
    /// those pockets at the asset's own alpha, which on an opaque JPEG is 1.0.
    /// Pickleball's wordmark came out as one blob with no counters at all.
    private static func keyOut(
        _ keys: [Colour], of bitmap: Bitmap, alpha: [Float]
    ) -> [Float] {
        var ramp = [Float](repeating: 0, count: alpha.count)
        var keyable = [Bool](repeating: false, count: alpha.count)
        for pixel in alpha.indices {
            let gap = Colour(bitmap, pixel).gap(to: keys)
            guard gap < ink else { continue }
            keyable[pixel] = true
            ramp[pixel] = min(1, max(0, (gap - edge) / (ink - edge)))
        }

        func neighbours(of pixel: Int) -> [Int] {
            var out: [Int] = []
            let x = pixel % bitmap.width
            if x > 0 { out.append(pixel - 1) }
            if x < bitmap.width - 1 { out.append(pixel + 1) }
            if pixel >= bitmap.width { out.append(pixel - bitmap.width) }
            if pixel + bitmap.width < alpha.count { out.append(pixel + bitmap.width) }
            return out
        }

        var keyed = [Bool](repeating: false, count: alpha.count)
        var queue: [Int] = []
        var head = 0

        func seed(_ pixel: Int) {
            guard keyable[pixel], !keyed[pixel] else { return }
            keyed[pixel] = true
            queue.append(pixel)
        }

        for x in 0..<bitmap.width {
            seed(x)
            seed((bitmap.height - 1) * bitmap.width + x)
        }
        for y in 0..<bitmap.height {
            seed(y * bitmap.width)
            seed(y * bitmap.width + bitmap.width - 1)
        }
        while head < queue.count {
            let pixel = queue[head]
            head += 1
            for next in neighbours(of: pixel) { seed(next) }
        }

        // What is left keyable is sealed inside the mark by construction: the
        // border fill already took everything it could reach.
        var walked = [Bool](repeating: false, count: alpha.count)
        for start in alpha.indices where keyable[start] && !keyed[start] && !walked[start] {
            var sealed = [start]
            var reader = 0
            walked[start] = true
            while reader < sealed.count {
                let pixel = sealed[reader]
                reader += 1
                for next in neighbours(of: pixel)
                where keyable[next] && !keyed[next] && !walked[next] {
                    walked[next] = true
                    sealed.append(next)
                }
            }
            guard sealed.count >= pocket else { continue }
            for pixel in sealed { keyed[pixel] = true }
        }

        // Partial coverage is an antialiased fringe: a pixel or two of blend
        // between the mark and the plate. A wide band of it is not a fringe
        // but a gradient in the artwork, and keeping it at half coverage is
        // what renders a chrome badge as a grey ghost instead of a white mark
        // — CBC Sport came out 52% solid, the thinnest-stroked wordmarks worse.
        // So the ramp applies where it can be a fringe of something, and the
        // gradient deeper in belongs to the mark.
        var mask = alpha
        for pixel in alpha.indices where keyed[pixel] {
            let fringe = ramp[pixel] <= 0.05
                || neighbours(of: pixel).contains { keyed[$0] && ramp[$0] <= 0.05 }
            mask[pixel] *= fringe ? ramp[pixel] : 1
        }
        return mask
    }

    /// The colours the border is actually made of, as 32-step buckets holding
    /// at least a twelfth of it. Capped, because past a handful of distinct
    /// fields the asset is a photograph and keying would eat the picture.
    private static func borderColours(of bitmap: Bitmap) -> [Colour] {
        var pixels: [Int] = []
        for x in 0..<bitmap.width {
            pixels.append(x)
            pixels.append((bitmap.height - 1) * bitmap.width + x)
        }
        for y in 0..<bitmap.height {
            pixels.append(y * bitmap.width)
            pixels.append(y * bitmap.width + bitmap.width - 1)
        }

        var buckets: [Int: (red: Int, green: Int, blue: Int, count: Int)] = [:]
        var total = 0
        for pixel in pixels {
            let base = pixel * 4
            guard bitmap.rgba[base + 3] > 127 else { continue }
            total += 1
            let red = Int(bitmap.rgba[base])
            let green = Int(bitmap.rgba[base + 1])
            let blue = Int(bitmap.rgba[base + 2])
            let bucket = (red >> 5) << 10 | (green >> 5) << 5 | (blue >> 5)
            var sum = buckets[bucket] ?? (0, 0, 0, 0)
            sum.red += red
            sum.green += green
            sum.blue += blue
            sum.count += 1
            buckets[bucket] = sum
        }
        guard total > 0 else { return [] }
        return buckets.values
            .filter { $0.count * 12 >= total }
            .sorted { $0.count > $1.count }
            .prefix(4)
            .map {
                Colour(
                    red: Float($0.red) / Float($0.count) / 255,
                    green: Float($0.green) / Float($0.count) / 255,
                    blue: Float($0.blue) / Float($0.count) / 255)
            }
    }

    // MARK: - Output

    /// The glyph's own bounds. Trimming to them is what lets a wide wordmark
    /// use the column's width instead of height-binding inside whatever square
    /// its asset was padded out to.
    private static func inkBounds(
        of mask: [Float], in bitmap: Bitmap
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            let row = y * bitmap.width
            for x in 0..<bitmap.width where mask[row + x] > 0.03 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private static func white(
        _ mask: [Float], of bitmap: Bitmap,
        in bounds: (x: Int, y: Int, width: Int, height: Int)
    ) -> PlatformImage? {
        var pixels = [UInt8](repeating: 0, count: bounds.width * bounds.height * 4)
        for y in 0..<bounds.height {
            let row = (bounds.y + y) * bitmap.width + bounds.x
            for x in 0..<bounds.width {
                let coverage = UInt8(min(255, max(0, (mask[row + x] * 255).rounded())))
                let base = (y * bounds.width + x) * 4
                // Premultiplied white: every channel is the coverage itself.
                pixels[base] = coverage
                pixels[base + 1] = coverage
                pixels[base + 2] = coverage
                pixels[base + 3] = coverage
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: bounds.width, height: bounds.height,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bounds.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent)
        else { return nil }
        #if os(macOS)
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: bounds.width, height: bounds.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    private struct Bitmap {
        var width: Int
        var height: Int
        var rgba: [UInt8]
    }

    private struct Colour {
        var red: Float
        var green: Float
        var blue: Float

        static let white = Colour(red: 1, green: 1, blue: 1)

        /// Close enough to white that keying white would key this too, so
        /// white is the honest name for the plate.
        var isLight: Bool { gap(to: [.white]) < ink }

        init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ bitmap: Bitmap, _ pixel: Int) {
            let base = pixel * 4
            red = Float(bitmap.rgba[base]) / 255
            green = Float(bitmap.rgba[base + 1]) / 255
            blue = Float(bitmap.rgba[base + 2]) / 255
        }

        /// Distance to the keyed set, 0...1. A blend *between* two keyed
        /// colours counts as keyed too, or the seam where two brand fields
        /// meet survives as a hairline of ink down the middle of the glyph.
        func gap(to keys: [Colour]) -> Float {
            var best = Float.greatestFiniteMagnitude
            for key in keys { best = min(best, distance(to: key)) }
            for (index, key) in keys.enumerated() {
                for other in keys[keys.index(after: index)...] {
                    best = min(best, distance(toBlendOf: key, and: other))
                }
            }
            return best / 1.7320508  // the longest gap in the RGB cube
        }

        private func distance(to other: Colour) -> Float {
            let red = red - other.red
            let green = green - other.green
            let blue = blue - other.blue
            return (red * red + green * green + blue * blue).squareRoot()
        }

        private func distance(toBlendOf first: Colour, and second: Colour) -> Float {
            let spanRed = second.red - first.red
            let spanGreen = second.green - first.green
            let spanBlue = second.blue - first.blue
            let span = spanRed * spanRed + spanGreen * spanGreen + spanBlue * spanBlue
            guard span > 0 else { return distance(to: first) }
            let along =
                ((red - first.red) * spanRed
                    + (green - first.green) * spanGreen
                    + (blue - first.blue) * spanBlue) / span
            let clamped = min(1, max(0, along))
            return distance(
                to: Colour(
                    red: first.red + spanRed * clamped,
                    green: first.green + spanGreen * clamped,
                    blue: first.blue + spanBlue * clamped))
        }
    }
}
