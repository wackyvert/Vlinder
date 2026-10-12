import SwiftUI

/// The synthesized Now Playing card's raw material: the brand field taken off a
/// channel logo, and that logo reduced to a silhouette big enough to be the
/// card's picture.
///
/// The column's job is a thumbnail of the programme. Real artwork comes first
/// and always, but measured on this server only about 1% of currently-airing
/// programmes carry an image — much higher on the ~114 Schedules Direct
/// channels, effectively zero on the ~1800 IPTV ones — so most rows are
/// synthesized, and a synthesized row still has to be a picture. Fubo
/// composites its matchup cards server-side from two team colours and two
/// crests, blown up and cropped into a split field. We have one asset where it
/// has two, so the equivalent is the channel's own mark at that scale and that
/// crop, on its own colours.
///
/// The thing to avoid was never the asset — it is drawing it in the same
/// register as the logo cell 12px to the left. The reference's own synthesized
/// row carries two crests bled off the card and the small FOX SPORTS oval in
/// the logo cell: same class of art, entirely different treatment.
enum GuideSlate {
    /// Colours the card is built from, derived once per channel.
    struct Palette: Equatable {
        var primary: Color
        var secondary: Color
        /// The channel's own hue held very near white, for the mark.
        ///
        /// It is the *step* from mark to ground that the card is measured on,
        /// and this is where it comes from. At S 0.26–0.52 the mark landed at
        /// L 134–146 and the step measured 91.9–160.1, against 190.5–195.8 on
        /// the reference's two graphic cards and 230.7 on our own logo cell
        /// drawing the same asset in the same screenshot — about 40% of the
        /// available contrast thrown away on saturation nobody asked for. A
        /// whisper of hue is all the mark needs; the saturated fields under it
        /// are what carry the brand.
        var accent: Color
        /// A stable arbitrary integer naming this channel's composition — where
        /// the seam falls, where the light is, how the mark is cropped. The
        /// card takes it modulo whatever it needs, so no count lives twice.
        ///
        /// ESPN, ESPN2 and CNN all own the same red — their cards measured
        /// within ΔRGB 12 of each other — so hue cannot tell them apart, and no
        /// hue that would is one any of the three owns. Geometry can: the same
        /// two colours, composed differently.
        var layout: Int
        /// True when the field came out light enough that white would vanish
        /// into it. Only ink-only artwork reaches this (the CBS eye is black on
        /// transparent and its card is correctly pale); a branded field is held
        /// dark on purpose.
        var wantsDarkInk: Bool
    }

    /// A channel's card material: its colours, and its mark as a silhouette.
    struct Art {
        var palette: Palette
        /// Nil when the asset yielded no silhouette worth blowing up — a
        /// photograph, or a tile whose ground could not be named. Those rows
        /// fall back to the field and its seam alone.
        var mark: PlatformImage?
    }

    @MainActor private static var cache: [String: Art] = [:]
    @MainActor private static var stand: [String: Art] = [:]

    /// The card material already read off a channel's logo, if it has been.
    @MainActor
    static func cachedArt(for channelId: String) -> Art? {
        cache[channelId]
    }

    /// The card drawn until the logo's pixels have been read.
    ///
    /// Channel logos are usually white on transparent, so it stands in the
    /// card that ink would earn anyway. Kept per channel, apart from the real
    /// card, so the real brand colour takes over as soon as it is ready.
    @MainActor
    static func placeholder(for channel: BaseItem) -> Art {
        if let hit = stand[channel.id] { return hit }
        let art = Art(palette: unbranded(named: channel.displayTitle, ink: 1), mark: nil)
        stand[channel.id] = art
        return art
    }

    @MainActor
    static func store(_ art: Art, for channelId: String) {
        cache[channelId] = art
    }

    /// Everything the card needs, read off the logo once per channel.
    ///
    /// The palette and the silhouette come off one decode and one keying pass,
    /// because they are answers to the same question — which pixels are the
    /// mark — and because a row scrolling past must not pay for either twice.
    ///
    /// Pure, and called off the main thread: it used to run inside the card's
    /// body, so the first frame a row with a cached logo scrolled into view
    /// paid for a decode and a flood-fill keying pass on the main thread.
    /// Nil when the logo has no bitmap to read.
    static func makeArt(named name: String, logo: PlatformImage) -> Art? {
        guard let bitmap = bitmap(of: logo) else { return nil }
        let coverage = inkCoverage(of: bitmap)
        return Art(
            palette: extract(from: bitmap, coverage: coverage, named: name),
            mark: silhouette(of: bitmap, coverage: coverage))
    }

    /// Longest side the logo is decoded to.
    ///
    /// The silhouette is drawn past the card's own height and at 2x backing,
    /// so the mask has to carry a few hundred pixels or the picture arrives
    /// mushy — which is what 160 gave. Keying 320² once per channel is cheap;
    /// keying it per render would not be, and nothing here runs per render.
    /// What the server holds is the real ceiling: its channel art is 96px.
    private static let maxSide = 320

    /// 15° per bucket: narrow enough to keep red apart from orange, wide enough
    /// that edge anti-aliasing does not split one brand colour across two.
    private static let bucketCount = 24

    private struct Bitmap {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        var count: Int { width * height }
    }

    /// A sampled colour, kept as numbers so a companion shade can be derived
    /// from it before either becomes a `Color`.
    private struct Field {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    /// The logo's modal chromatic hue, and a companion field for it.
    ///
    /// Voting, not averaging: a logo is mostly transparent, white or black, so
    /// its mean is a near-grey, and a near-grey forced up to a usable
    /// saturation lands on whatever hue the rounding left behind — which is how
    /// these slates came to sit ~135° off the channels' own colours, and
    /// near-complementary on four rows of six.
    private static func extract(
        from bitmap: Bitmap, coverage: [Double], named name: String
    ) -> Palette {
        var weight = [Double](repeating: 0, count: bucketCount)
        var satWeight = weight, briWeight = weight, sine = weight, cosine = weight
        var inkWeight = 0.0, inkTotal = 0.0

        for cell in coverage.indices {
            // Anti-aliased edges are artwork blended into the ground; at low
            // coverage that blend is mostly ground and its hue is noise.
            let ink = coverage[cell]
            guard ink > 0.5 else { continue }
            let colour = hsb(sample(bitmap, cell))
            inkWeight += colour.brightness * ink
            inkTotal += ink

            // Only chromatic pixels carry a brand hue, and on a typical
            // wordmark the white, black and grey ones outnumber them several
            // to one.
            guard colour.saturation >= 0.28,
                  colour.brightness >= 0.16, colour.brightness <= 0.98
            else { continue }

            let bucket = min(Int(colour.hue * Double(bucketCount)), bucketCount - 1)
            let vote = colour.saturation * ink
            let angle = colour.hue * 2 * .pi
            weight[bucket] += vote
            satWeight[bucket] += colour.saturation * vote
            briWeight[bucket] += colour.brightness * vote
            sine[bucket] += sin(angle) * vote
            cosine[bucket] += cos(angle) * vote
        }
        guard inkTotal > 0 else { return unbranded(named: name, ink: 1) }

        func neighbours(_ bucket: Int) -> [Int] {
            [(bucket + bucketCount - 1) % bucketCount, bucket, (bucket + 1) % bucketCount]
        }
        // Score each bucket together with its neighbours, so a brand colour
        // that straddles a boundary is still counted as one colour.
        let score = (0..<bucketCount).map { bucket in
            neighbours(bucket).reduce(0) { $0 + weight[$1] }
        }
        guard let lead = score.indices.max(by: { score[$0] < score[$1] }),
              score[lead] > 0
        else {
            // Genuinely monochrome artwork — the CBS eye the server sends is
            // black on transparent, not one coloured pixel in it.
            return unbranded(named: name, ink: inkWeight / inkTotal)
        }

        func field(at bucket: Int) -> Field {
            let picked = neighbours(bucket)
            let hue = atan2(
                picked.reduce(0) { $0 + sine[$1] },
                picked.reduce(0) { $0 + cosine[$1] }) / (2 * .pi)
            return Field(
                hue: hue < 0 ? hue + 1 : hue,
                saturation: picked.reduce(0) { $0 + satWeight[$1] } / score[bucket],
                brightness: picked.reduce(0) { $0 + briWeight[$1] } / score[bucket])
        }

        // A second brand hue counts only when it is a genuinely different
        // colour carrying real weight. A one-colour wordmark has none, and
        // inventing one would put a hue on the card the channel does not own.
        let rival = (0..<bucketCount)
            .filter { distance(from: $0, to: lead) >= 4 }
            .max(by: { score[$0] < score[$1] })
        if let rival, score[rival] >= score[lead] * 0.3 {
            return branded(
                primary: field(at: lead), secondary: field(at: rival),
                depth: 0.58, named: name)
        }
        return branded(
            primary: field(at: lead), secondary: field(at: lead),
            depth: 0.26, deepen: 0.06, named: name)
    }

    /// Buckets apart the short way round the wheel.
    private static func distance(from: Int, to: Int) -> Int {
        let step = abs(from - to)
        return min(step, bucketCount - step)
    }

    private static func branded(
        primary: Field, secondary: Field,
        depth: Double, deepen: Double = 0, named name: String
    ) -> Palette {
        Palette(
            primary: paint(primary),
            secondary: paint(secondary, depth: depth, deepen: deepen),
            accent: Color(
                hue: primary.hue,
                saturation: min(max(primary.saturation * 0.20, 0.07), 0.20),
                brightness: 0.99),
            layout: layout(of: name),
            wantsDarkInk: false)
    }

    /// Turn a sampled field into a drawable colour.
    ///
    /// The band brackets the reference's own synthesized field (V 33.9) and its
    /// filler card (V 19.4), and it is deliberately wide. Our cards measured
    /// luminance sd 30.9–48.0 where the reference's flattest is 51.6, and the
    /// live frame's between-card mean-RGB distance was 54.3 against the
    /// reference's 110.2 — both are the same shortage of range. Passing more of
    /// the artwork's own brightness through (×0.50 rather than ×0.36) widens
    /// the spread between channels, and taking the second field deeper widens
    /// it within each card.
    ///
    /// `depth` shades a companion field; `deepen` saturates a same-hue shade so
    /// it reads as a second colour rather than as a dimmer. It runs deep on
    /// purpose: the reference card's luminance sd of 51.6 comes from a genuinely
    /// dark half under a bright crest, and two mid fields under a bright mark
    /// measured 20–36.
    private static func paint(
        _ field: Field, depth: Double = 1, deepen: Double = 0
    ) -> Color {
        Color(
            hue: field.hue,
            saturation: min(max(field.saturation * 1.2 + deepen, 0.55), 1),
            brightness: min(max(0.26 + field.brightness * 0.50, 0.34), 0.74) * depth)
    }

    // MARK: - The mark

    /// The mark alone, as premultiplied white, trimmed to its own ink.
    ///
    /// Trimming is the whole point. The server floats a 96×96 glyph in a
    /// square, and a card sized to the *image* wears the padding: the old code
    /// cut only pixels under `alpha > 30`, which on the eight fully-opaque
    /// assets this server ships cut nothing at all, pinning every subject to
    /// 100×100 — 48.2% of a 192×108 card, against the reference's 78.1%. Keying
    /// the ground out first is what recovers a real bounding box, and with it
    /// the glyph's true aspect: the ESPN, FOX and CBC wordmarks are all wider
    /// than 1.5:1, and the card can crop rather than letterbox them.
    private static func silhouette(of bitmap: Bitmap, coverage: [Double]) -> PlatformImage? {
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        var inked = 0.0
        for y in 0..<bitmap.height {
            let row = y * bitmap.width
            for x in 0..<bitmap.width where coverage[row + x] > 0.03 {
                inked += coverage[row + x]
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let width = maxX - minX + 1, height = maxY - minY + 1

        // Nothing keyed out: a photograph, or a tile whose ground we could not
        // name. Blown up to twice the card, that is a smear rather than a
        // picture, so the row keeps the field and its seam instead.
        guard inked / Double(width * height) < 0.92 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = (minY + y) * bitmap.width + minX
            for x in 0..<width {
                let ink = UInt8(min(255, max(0, (coverage[row + x] * 255).rounded())))
                let base = (y * width + x) * 4
                // Premultiplied white: every channel is the coverage itself.
                pixels[base] = ink
                pixels[base + 1] = ink
                pixels[base + 2] = ink
                pixels[base + 3] = ink
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent)
        else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    // MARK: - Sampling

    /// A straight-alpha RGBA copy of the asset, capped to `maxSide`.
    private static func bitmap(of image: PlatformImage) -> Bitmap? {
        guard let cgImage = cgImage(of: image) else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(cgImage.width, cgImage.height)))
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        // Drawn inside the closure: the context borrows the buffer, so it must
        // not outlive it.
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
        return drawn ? Bitmap(width: width, height: height, rgba: rgba) : nil
    }

    /// How much of each pixel is mark rather than ground.
    ///
    /// Two kinds of asset arrive here. One has a real alpha channel, where the
    /// alpha *is* the answer. The other is flattened — and on this server that
    /// is most of them: BIGTEN, ESPN, ESPN2, FOX9, FOXSP1, CNN, CNBC and
    /// PICKLEBALL each measure 9216/9216 px opaque, so an alpha test passes
    /// every pixel, the ground votes on the brand colour beside the mark, and
    /// the mark's own bounding box comes out as the whole square. For those the
    /// ground is keyed out the way the logo cell keys it: flooded from the
    /// border, so white knocked *out* of a red field is never reached from
    /// outside, and on a soft ramp, because hard-thresholding chews the glyph
    /// edges.
    private static func inkCoverage(of bitmap: Bitmap) -> [Double] {
        var coverage = [Double](repeating: 0, count: bitmap.count)
        var clear = 0
        for cell in 0..<bitmap.count {
            let alpha = Double(bitmap.rgba[cell * 4 + 3]) / 255
            coverage[cell] = alpha
            if alpha < 0.12 { clear += 1 }
        }
        // A fifth of the frame transparent means the artwork brought its own
        // mask and there is nothing to guess at.
        if clear * 5 >= bitmap.count { return coverage }

        // Light ground is the common flattened case and safe to key on its own;
        // a full-bleed brand field needs the border's own colours, which are
        // only trustworthy once white has been ruled out, since on a full-bleed
        // asset it is the mark that touches the edge.
        let light = keyOut([(1, 1, 1)], from: bitmap, coverage: coverage)
        if light.share >= 0.10 { return light.coverage }
        let fields = borderColours(of: bitmap)
        guard !fields.isEmpty else { return coverage }
        return keyOut(fields, from: bitmap, coverage: coverage).coverage
    }

    private typealias Sample = (red: Double, green: Double, blue: Double)

    /// Within `groundGap` of a keyed colour a pixel is ground; past `inkGap` it
    /// is mark; between the two it keeps its partial coverage.
    private static let groundGap = 0.06
    private static let inkGap = 0.30

    /// Flood the keyed colours out from the border, and report what share of
    /// the frame that reached.
    private static func keyOut(
        _ keys: [Sample], from bitmap: Bitmap, coverage: [Double]
    ) -> (coverage: [Double], share: Double) {
        var coverage = coverage
        var visited = [Bool](repeating: false, count: coverage.count)
        var queue: [Int] = []
        var keyed = 0

        func consider(_ cell: Int) {
            guard !visited[cell] else { return }
            let distance = gap(of: sample(bitmap, cell), to: keys)
            guard distance < inkGap else { return }
            visited[cell] = true
            coverage[cell] *= min(1, max(0, (distance - groundGap) / (inkGap - groundGap)))
            keyed += 1
            queue.append(cell)
        }

        for x in 0..<bitmap.width {
            consider(x)
            consider((bitmap.height - 1) * bitmap.width + x)
        }
        for y in 0..<bitmap.height {
            consider(y * bitmap.width)
            consider(y * bitmap.width + bitmap.width - 1)
        }
        var head = 0
        while head < queue.count {
            let cell = queue[head]
            head += 1
            let x = cell % bitmap.width
            if x > 0 { consider(cell - 1) }
            if x < bitmap.width - 1 { consider(cell + 1) }
            if cell >= bitmap.width { consider(cell - bitmap.width) }
            if cell + bitmap.width < coverage.count { consider(cell + bitmap.width) }
        }
        return (coverage, Double(keyed) / Double(coverage.count))
    }

    /// The colours the border is actually made of, as 32-step buckets holding at
    /// least a twelfth of it. Capped, because past a handful of distinct fields
    /// the asset is a photograph and keying would eat the picture.
    private static func borderColours(of bitmap: Bitmap) -> [Sample] {
        var cells: [Int] = []
        for x in 0..<bitmap.width {
            cells.append(x)
            cells.append((bitmap.height - 1) * bitmap.width + x)
        }
        for y in 0..<bitmap.height {
            cells.append(y * bitmap.width)
            cells.append(y * bitmap.width + bitmap.width - 1)
        }

        var buckets: [Int: (sum: Sample, count: Int)] = [:]
        var total = 0
        for cell in cells {
            guard bitmap.rgba[cell * 4 + 3] > 127 else { continue }
            total += 1
            let colour = sample(bitmap, cell)
            let bucket = (Int(colour.red * 255) >> 5) << 10
                | (Int(colour.green * 255) >> 5) << 5
                | (Int(colour.blue * 255) >> 5)
            var entry = buckets[bucket] ?? ((0, 0, 0), 0)
            entry.sum = (
                entry.sum.red + colour.red,
                entry.sum.green + colour.green,
                entry.sum.blue + colour.blue)
            entry.count += 1
            buckets[bucket] = entry
        }
        guard total > 0 else { return [] }
        return buckets.values
            .filter { $0.count * 12 >= total }
            .sorted { $0.count > $1.count }
            .prefix(4)
            .map { entry in
                let n = Double(entry.count)
                return (entry.sum.red / n, entry.sum.green / n, entry.sum.blue / n)
            }
    }

    /// Straight-alpha colour of one pixel. Un-premultiplied, or an antialiased
    /// edge reads as a blend towards black and keys against the wrong colour.
    private static func sample(_ bitmap: Bitmap, _ cell: Int) -> Sample {
        let offset = cell * 4
        let alpha = max(Double(bitmap.rgba[offset + 3]) / 255, 1.0 / 255)
        return (
            min(1, Double(bitmap.rgba[offset]) / 255 / alpha),
            min(1, Double(bitmap.rgba[offset + 1]) / 255 / alpha),
            min(1, Double(bitmap.rgba[offset + 2]) / 255 / alpha))
    }

    /// Distance from a colour to the keyed set, 0...1. A blend *between* two
    /// keyed colours counts as keyed too, or the seam where two ground fields
    /// meet survives as a hairline of ink across the mark.
    private static func gap(of colour: Sample, to keys: [Sample]) -> Double {
        func distance(_ a: Sample, _ b: Sample) -> Double {
            let red = a.red - b.red, green = a.green - b.green, blue = a.blue - b.blue
            return (red * red + green * green + blue * blue).squareRoot()
        }
        var best = Double.greatestFiniteMagnitude
        for key in keys { best = min(best, distance(colour, key)) }
        for (index, key) in keys.enumerated() {
            for other in keys[keys.index(after: index)...] {
                let span = (
                    other.red - key.red, other.green - key.green, other.blue - key.blue)
                let length = span.0 * span.0 + span.1 * span.1 + span.2 * span.2
                guard length > 0 else { continue }
                let along = min(1, max(0, (
                    (colour.red - key.red) * span.0
                        + (colour.green - key.green) * span.1
                        + (colour.blue - key.blue) * span.2) / length))
                best = min(best, distance(colour, (
                    key.red + span.0 * along,
                    key.green + span.1 * along,
                    key.blue + span.2 * along)))
            }
        }
        return best / 1.7320508  // the longest gap in the RGB cube
    }

    private static func cgImage(of image: PlatformImage) -> CGImage? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
        #else
        return image.cgImage
        #endif
    }

    private static func hsb(_ colour: Sample)
        -> (hue: Double, saturation: Double, brightness: Double) {
        let high = max(colour.red, colour.green, colour.blue)
        let low = min(colour.red, colour.green, colour.blue)
        let chroma = high - low
        guard chroma > 0 else { return (0, 0, high) }
        var sixth: Double
        switch high {
        case colour.red: sixth = (colour.green - colour.blue) / chroma
        case colour.green: sixth = (colour.blue - colour.red) / chroma + 2
        default: sixth = (colour.red - colour.green) / chroma + 4
        }
        sixth = (sixth / 6).truncatingRemainder(dividingBy: 1)
        return (sixth < 0 ? sixth + 1 : sixth, chroma / high, high)
    }

    /// A card for a logo that is pure ink.
    ///
    /// Black-and-white artwork has no brand hue to take, so the ink picks the
    /// card instead: dark ink gets a light card, light ink a dark one, which is
    /// how the reference's own wordmark card sits — a near-white card at S 10,
    /// V 91 under a dark wordmark. The hue is here only so two such channels
    /// are not the same card, and it stays faint because it is not the
    /// channel's colour to claim.
    private static func unbranded(named name: String, ink: Double) -> Palette {
        let hue = hue(of: name)
        let level = ink < 0.5 ? 0.82 : 0.34
        let dark = level > 0.62
        var saturation = (primary: 0.10, secondary: 0.16)
        var brightness = level
        #if os(tvOS)
        // On the TV a white-ink card is not allowed to be grey. The fixture's
        // three broadcast networks arrive from the tuner as pure white glyphs
        // on transparent — zero chromatic pixels in the source asset, so
        // there is no brand colour to extract and this is the path they take
        // — and at S 0.10 their cards measured chroma 5–7 against 31–58 on the
        // rows beside them: three grey boxes at the top of the column, which
        // GUIDE_SPEC calls a failure outright. The hue is still the name's,
        // not a colour the channel owns, but from ten feet a committed field
        // under a white mark reads as a card and a faint one reads as
        // unfinished. The pale (dark-ink) card keeps its whisper: it is the
        // reference's own near-white wordmark card.
        if !dark {
            saturation = (0.58, 0.70)
            brightness = 0.46
        }
        #endif
        return Palette(
            primary: Color(hue: hue, saturation: saturation.primary, brightness: brightness),
            secondary: Color(hue: hue, saturation: saturation.secondary, brightness: brightness * 0.84),
            // The mark has to darken a pale card and lighten a dark one, or the
            // picture disappears into the only field it has.
            accent: Color(white: dark ? 0.14 : 0.96),
            layout: layout(of: name),
            wantsDarkInk: dark)
    }

    /// Stable hue from the name, so two colourless channels still get their own
    /// card and keep it between renders.
    private static func hue(of name: String) -> Double {
        Double(hash(of: name) % 360) / 360
    }

    /// Taken off a different slice of the hash than the hue, so two channels
    /// that collide on one do not collide on both.
    private static func layout(of name: String) -> Int {
        Int(hash(of: name) >> 20 & 0x7FFF_FFFF)
    }

    private static func hash(of name: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash << 5) &+ hash &+ UInt64(byte) }
        return hash
    }
}
