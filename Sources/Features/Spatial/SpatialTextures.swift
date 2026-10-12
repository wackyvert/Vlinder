import CoreGraphics
import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Generated textures and the resolved palette for the Atrium. Everything here
// is CoreGraphics/CoreText only, safe to run off the main thread, and returns
// CGImage so SceneKit materials can consume it on any platform.

/// Atrium colors resolved for one appearance. The design translates the
/// Kaleidescape-style cinema void: artwork is the only light source, chrome
/// stays near-invisible, selection is a warm rim.
struct AtriumPalette: Equatable {
    var isDark: Bool

    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    /// Back-wall surface behind each bay's posters.
    var wall: CGColor
    var posterBacking: CGColor
    var placeholderBase: CGColor
    var placeholderMark: CGColor
    var labelPrimary: CGColor
    var labelSecondary: CGColor
    var rim: CGColor
    var accent: CGColor
    var progressTrack: CGColor
    /// Case shell stock, and the spine it is printed on.
    var caseShell: CGColor
    var spineGround: CGColor
    /// Shelf furniture: board top, its front edge, and the panel behind.
    var shelfBoard: CGColor
    var shelfEdge: CGColor
    var backPanel: CGColor
    /// Warm strip under the shelf above, lighting the row.
    var shelfLight: CGColor

    static func palette(dark: Bool) -> AtriumPalette {
        if dark {
            AtriumPalette(
                isDark: true,
                backgroundTop: CGColor(srgbRed: 0.078, green: 0.094, blue: 0.122, alpha: 1),
                backgroundBottom: CGColor(srgbRed: 0.020, green: 0.024, blue: 0.039, alpha: 1),
                wall: CGColor(srgbRed: 0.094, green: 0.106, blue: 0.129, alpha: 1),
                posterBacking: CGColor(srgbRed: 0.098, green: 0.106, blue: 0.129, alpha: 1),
                placeholderBase: CGColor(srgbRed: 0.090, green: 0.102, blue: 0.125, alpha: 1),
                placeholderMark: CGColor(srgbRed: 0.149, green: 0.169, blue: 0.200, alpha: 1),
                labelPrimary: CGColor(srgbRed: 0.910, green: 0.902, blue: 0.882, alpha: 0.92),
                labelSecondary: CGColor(srgbRed: 0.910, green: 0.902, blue: 0.882, alpha: 0.50),
                rim: CGColor(srgbRed: 1.0, green: 0.976, blue: 0.930, alpha: 1),
                accent: CGColor(srgbRed: 0.851, green: 0.643, blue: 0.255, alpha: 1),
                progressTrack: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
                caseShell: CGColor(srgbRed: 0.075, green: 0.079, blue: 0.090, alpha: 1),
                spineGround: CGColor(srgbRed: 0.113, green: 0.119, blue: 0.135, alpha: 1),
                shelfBoard: CGColor(srgbRed: 0.130, green: 0.110, blue: 0.088, alpha: 1),
                shelfEdge: CGColor(srgbRed: 0.163, green: 0.138, blue: 0.110, alpha: 1),
                backPanel: CGColor(srgbRed: 0.072, green: 0.068, blue: 0.066, alpha: 1),
                shelfLight: CGColor(srgbRed: 0.96, green: 0.86, blue: 0.70, alpha: 1))
        } else {
            AtriumPalette(
                isDark: false,
                backgroundTop: CGColor(srgbRed: 0.957, green: 0.949, blue: 0.933, alpha: 1),
                backgroundBottom: CGColor(srgbRed: 0.839, green: 0.827, blue: 0.804, alpha: 1),
                wall: CGColor(srgbRed: 0.851, green: 0.839, blue: 0.816, alpha: 1),
                posterBacking: CGColor(srgbRed: 0.235, green: 0.243, blue: 0.263, alpha: 1),
                placeholderBase: CGColor(srgbRed: 0.878, green: 0.867, blue: 0.847, alpha: 1),
                placeholderMark: CGColor(srgbRed: 0.780, green: 0.769, blue: 0.749, alpha: 1),
                labelPrimary: CGColor(srgbRed: 0.086, green: 0.094, blue: 0.110, alpha: 0.95),
                labelSecondary: CGColor(srgbRed: 0.086, green: 0.094, blue: 0.110, alpha: 0.66),
                rim: CGColor(srgbRed: 0.659, green: 0.467, blue: 0.094, alpha: 1),
                accent: CGColor(srgbRed: 0.659, green: 0.467, blue: 0.094, alpha: 1),
                progressTrack: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16),
                caseShell: CGColor(srgbRed: 0.196, green: 0.200, blue: 0.212, alpha: 1),
                spineGround: CGColor(srgbRed: 0.243, green: 0.247, blue: 0.259, alpha: 1),
                shelfBoard: CGColor(srgbRed: 0.541, green: 0.463, blue: 0.373, alpha: 1),
                shelfEdge: CGColor(srgbRed: 0.612, green: 0.529, blue: 0.435, alpha: 1),
                backPanel: CGColor(srgbRed: 0.788, green: 0.769, blue: 0.741, alpha: 1),
                shelfLight: CGColor(srgbRed: 1.0, green: 0.973, blue: 0.914, alpha: 1))
        }
    }
}

enum SpatialTextures {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Drops generated textures (palette-dependent). Decoded artwork sources
    /// are palette-independent and deliberately survive an appearance change.
    static func flushCache() {
        cache.removeAllObjects()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Text

    private static func systemFont(size: CGFloat, weight: PlatformFontWeight) -> PlatformFont {
        #if os(macOS)
        NSFont.systemFont(ofSize: size, weight: weight)
        #else
        UIFont.systemFont(ofSize: size, weight: weight)
        #endif
    }

    // NSFont/UIFont are toll-free bridged to CTFont, so passing them under
    // kCTFontAttributeName is the supported CoreText pattern.
    private static func line(_ text: String, font: PlatformFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    private static func truncated(_ line: CTLine, width: Double, font: PlatformFont, color: CGColor) -> CTLine {
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return line }
        let token = Self.line("…", font: font, color: color)
        return CTLineCreateTruncatedLine(line, width, .end, token) ?? line
    }

    private static func drawCentered(_ line: CTLine, in ctx: CGContext, width: Int, baselineY: CGFloat) {
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: baselineY)
        CTLineDraw(line, ctx)
    }

    // MARK: - Poster label

    // MARK: - Badges

    /// Unplayed-count pill: dark glass capsule, white count.
    static func countBadge(_ count: Int, palette: AtriumPalette) -> CGImage? {
        let text = count > 99 ? "99+" : "\(count)"
        let key = "count|\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let height = 88
        let font = systemFont(size: 52, weight: .semibold)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        let textLine = line(text, font: font, color: white)
        let textWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
        let width = max(height, Int(textWidth) + 56)
        guard let ctx = context(width: width, height: height) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(height) / 2, cornerHeight: CGFloat(height) / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.045, blue: 0.06, alpha: 0.82))
        ctx.fillPath()
        drawCentered(textLine, in: ctx, width: width, baselineY: 26)

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Watched check: small warm-white check in a dark glass disc.
    static func watchedBadge(palette: AtriumPalette) -> CGImage? {
        let key = "watched" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let side = 88
        guard let ctx = context(width: side, height: side) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.addEllipse(in: rect)
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.045, blue: 0.06, alpha: 0.82))
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.976, blue: 0.93, alpha: 0.95))
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 24, y: 44))
        ctx.addLine(to: CGPoint(x: 38, y: 30))
        ctx.addLine(to: CGPoint(x: 64, y: 58))
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The spine, printed the way a real case is: title running up the edge in
    /// small caps, a smaller line at the foot — the year for a film, the number
    /// for an episode, the episode count for a season. The texture is tall and
    /// narrow to match the spine face, and the text is drawn rotated so it
    /// reads bottom-to-top.
    static func spine(
        title: String,
        footnote: String?,
        tint: CGColor?,
        palette: AtriumPalette
    ) -> CGImage? {
        let tintKey = tint?.components?.prefix(3).map { String(format: "%.2f", $0) }.joined() ?? "-"
        let key = "spine|\(palette.isDark)|\(tintKey)|\(title)|\(footnote ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let width = 80, height = 790
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(tint ?? palette.spineGround)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // A hairline of the accent at the head, like a publisher's band.
        ctx.setFillColor(palette.accent)
        ctx.fill(CGRect(x: 0, y: height - 26, width: width, height: 5))

        // Rotate so the baseline runs up the spine.
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(width) / 2, y: 46)
        ctx.rotate(by: .pi / 2)

        // A tinted spine needs its ink chosen against the tint, not the room.
        let ink = tint.map { Self.readableInk(on: $0) } ?? palette.labelPrimary
        let inkDim = tint.map { Self.readableInk(on: $0, dim: true) } ?? palette.labelSecondary

        let span = Double(height) - 130
        var titleSpan = span
        var footLine: CTLine?
        if let footnote, !footnote.isEmpty {
            let footFont = systemFont(size: 30, weight: .regular)
            let measured = line(footnote, font: footFont, color: inkDim)
            footLine = measured
            titleSpan = span - CTLineGetTypographicBounds(measured, nil, nil, nil) - 26
        }

        let titleFont = systemFont(size: 40, weight: .semibold)
        let titleLine = truncated(
            line(title.uppercased(), font: titleFont, color: ink),
            width: max(80, titleSpan), font: titleFont, color: ink)
        ctx.textPosition = CGPoint(x: 0, y: -14)
        CTLineDraw(titleLine, ctx)

        if let footLine {
            let footWidth = CGFloat(CTLineGetTypographicBounds(footLine, nil, nil, nil))
            ctx.textPosition = CGPoint(x: span - Double(footWidth), y: -14)
            CTLineDraw(footLine, ctx)
        }
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Average colour of a cover, darkened into something a spine could
    /// plausibly be printed in. Runs on a 1x1 downsample, so it is cheap enough
    /// to do for every case on the shelf.
    static func spineTint(from image: CGImage) -> CGColor? {
        guard let ctx = context(width: 1, height: 1) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        var r = CGFloat(pixel[0]) / 255
        var g = CGFloat(pixel[1]) / 255
        var b = CGFloat(pixel[2]) / 255
        // Pull toward a printable range: shelf stock is never pure white or
        // pure black, and an over-saturated spine would shout.
        let mean = (r + g + b) / 3
        let target: CGFloat = 0.21
        let scale = mean > 0.02 ? target / mean : 1
        r = min(max(r * scale, 0.035), 0.50)
        g = min(max(g * scale, 0.035), 0.50)
        b = min(max(b * scale, 0.035), 0.50)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func readableInk(on tint: CGColor, dim: Bool = false) -> CGColor {
        let c = tint.components ?? [0, 0, 0, 1]
        let luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        let light = luma < 0.45
        let alpha: CGFloat = dim ? 0.58 : 0.95
        return light
            ? CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: alpha)
            : CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: alpha)
    }

    // MARK: - Printed jackets

    /// How a jacket is put together when the artwork alone will not do.
    enum JacketStyle {
        /// A wide still across the top, the episode printed underneath.
        case stillAbovePrint
        /// The show's poster full-bleed, the season printed across its foot.
        case printedFoot
    }

    /// Prints a jacket for a case whose artwork is not a poster of its own: an
    /// episode's wide still with the number and title set beneath it, or a
    /// season's inherited poster with the season named across its foot. Either
    /// way the ground is mixed from the artwork, so a shelf of episodes reads
    /// as a run of related colours rather than a row of identical stock.
    ///
    /// `art` may be nil — a still the server never made — and the jacket is
    /// then printed on plain stock with the number standing in for the picture.
    static func jacket(
        art: CGImage?,
        style: JacketStyle,
        kicker: String?,
        title: String,
        palette: AtriumPalette,
        aspect: CGFloat,
        maxPixel: CGFloat = 780
    ) -> CGImage? {
        let height = Int(maxPixel)
        let width = max(1, Int(maxPixel * aspect))
        guard let ctx = context(width: width, height: height) else { return nil }

        // Card stock, not ink: a jacket has to carry print, so it sits darker
        // than the spine mixed from the same artwork.
        let ground = art.flatMap { spineTint(from: $0).map { stock($0, scale: 0.58) } }
            ?? palette.spineGround
        ctx.setFillColor(ground)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let inset = CGFloat(width) * 0.058
        let textWidth = CGFloat(width) - inset * 2

        switch style {
        case .stillAbovePrint:
            let ink = readableInk(on: ground)
            let inkDim = readableInk(on: ground, dim: true)

            // 3:2 rather than the still's own 16:9: a shallower crop wastes
            // less of the face and sits better over the print below it.
            let artHeight = CGFloat(width) * 2 / 3
            let artRect = CGRect(
                x: 0, y: CGFloat(height) - artHeight,
                width: CGFloat(width), height: artHeight)
            if let art, let framed = resampled(art, maxPixel: CGFloat(width), aspect: 1.5) {
                ctx.draw(framed, in: artRect)
                // A still is lit for television, not for print: hold the
                // highlights back a little and sink its foot into the stock.
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.12))
                ctx.fill(artRect)
                let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let fade = CGGradient(
                    colorsSpace: space,
                    colors: [
                        ground.copy(alpha: 0.92) ?? ground,
                        ground.copy(alpha: 0) ?? ground,
                    ] as CFArray,
                    locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.clip(to: artRect)
                    ctx.drawLinearGradient(
                        fade,
                        start: CGPoint(x: 0, y: artRect.minY),
                        end: CGPoint(x: 0, y: artRect.minY + artHeight * 0.22),
                        options: [])
                    ctx.restoreGState()
                }
            } else if let kicker {
                // No still: the number itself is the picture.
                ctx.setFillColor(palette.isDark
                    ? CGColor(gray: 1, alpha: 0.05)
                    : CGColor(gray: 0, alpha: 0.06))
                ctx.fill(artRect)
                let font = systemFont(size: artHeight * 0.34, weight: .bold)
                drawCentered(
                    line(kicker, font: font, color: inkDim),
                    in: ctx, width: width,
                    baselineY: artRect.midY - font.ascender / 2)
            }

            // The print is set up from the foot, so every jacket keeps the same
            // bottom margin however far its title runs.
            let titleFont = systemFont(size: maxPixel * 0.055, weight: .semibold)
            let lineHeight = titleFont.ascender - titleFont.descender
            let panel = artRect.minY - inset * 1.6
            let lines = wrapped(
                title, font: titleFont, color: ink, width: textWidth,
                lineLimit: min(4, max(1, Int((panel - inset * 3) / lineHeight))))
            var baseline = inset * 1.3 - titleFont.descender
            for printed in lines.reversed() {
                ctx.textPosition = CGPoint(x: inset, y: baseline)
                CTLineDraw(printed, ctx)
                baseline += lineHeight
            }
            var top = baseline - lineHeight + titleFont.ascender

            if let kicker {
                let font = systemFont(size: maxPixel * 0.038, weight: .semibold)
                let printed = truncated(
                    line(kicker.uppercased(), font: font, color: inkDim),
                    width: Double(textWidth), font: font, color: inkDim)
                top += inset * 0.5
                ctx.textPosition = CGPoint(x: inset, y: top)
                CTLineDraw(printed, ctx)
                top += font.ascender
            }

            // A publisher's rule over the print, echoing the spine's band.
            ctx.setFillColor(palette.accent)
            ctx.fill(CGRect(
                x: inset, y: min(top + inset * 0.6, panel),
                width: CGFloat(width) * 0.16, height: 5))

        case .printedFoot:
            if let art, let framed = resampled(art, maxPixel: maxPixel, aspect: aspect) {
                ctx.draw(framed, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            // A scrim, so the print reads over whatever the poster is doing.
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88),
                    CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
                ] as CFArray,
                locations: [0, 1]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: CGFloat(height) * 0.46),
                    options: [])
            }

            let white = CGColor(srgbRed: 1, green: 0.99, blue: 0.97, alpha: 0.97)
            let dim = CGColor(srgbRed: 1, green: 0.99, blue: 0.97, alpha: 0.62)
            let titleFont = systemFont(size: maxPixel * 0.072, weight: .bold)
            let lineHeight = titleFont.ascender - titleFont.descender
            let lines = wrapped(
                title, font: titleFont, color: white, width: textWidth, lineLimit: 2)
            // Printed up from the foot, so the last line always clears the edge.
            var baseline = inset - titleFont.descender
            for printed in lines.reversed() {
                ctx.textPosition = CGPoint(x: inset, y: baseline)
                CTLineDraw(printed, ctx)
                baseline += lineHeight
            }
            if let kicker {
                let font = systemFont(size: maxPixel * 0.036, weight: .semibold)
                ctx.textPosition = CGPoint(
                    x: inset,
                    y: baseline - lineHeight + titleFont.ascender + inset * 0.4)
                CTLineDraw(line(kicker.uppercased(), font: font, color: dim), ctx)
            }
        }

        return ctx.makeImage()
    }

    /// Mixes a printable card stock from an ink colour: same hue, darker, so
    /// white type set on it reads at a distance.
    private static func stock(_ color: CGColor, scale: CGFloat) -> CGColor {
        let c = color.components ?? [0, 0, 0, 1]
        return CGColor(
            srgbRed: min(max(c[0] * scale, 0.02), 1),
            green: min(max(c[1] * scale, 0.02), 1),
            blue: min(max(c[2] * scale, 0.02), 1),
            alpha: 1)
    }

    /// Breaks `text` into at most `lineLimit` lines of `width`, ellipsing the
    /// last one if the text runs past it. Returns them in reading order; the
    /// caller places them, because a jacket sets some blocks from the top and
    /// some up from the foot.
    private static func wrapped(
        _ text: String,
        font: PlatformFont,
        color: CGColor,
        width: CGFloat,
        lineLimit: Int
    ) -> [CTLine] {
        guard lineLimit > 0, width > 0 else { return [] }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        let length = attributed.length

        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < lineLimit {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard suggested > 0 else { break }
            if lines.count == lineLimit - 1, start + suggested < length {
                // Truncate against the whole remainder, so the ellipsis lands
                // where the text actually runs out rather than at the break.
                let remainder = CTTypesetterCreateLine(
                    typesetter, CFRange(location: start, length: length - start))
                let token = line("…", font: font, color: color)
                lines.append(
                    CTLineCreateTruncatedLine(remainder, Double(width), .end, token)
                        ?? CTTypesetterCreateLine(
                            typesetter, CFRange(location: start, length: suggested)))
            } else {
                lines.append(
                    CTTypesetterCreateLine(typesetter, CFRange(location: start, length: suggested)))
            }
            start += suggested
        }
        return lines
    }

    /// Equirectangular environment for image-based lighting. Physically based
    /// materials need something to reflect or they render as flat paint; this
    /// gives them a warm ceiling, a mid horizon and a dark floor, plus a bright
    /// band standing in for the shelf's own strip light.
    static func environmentMap(palette: AtriumPalette) -> CGImage? {
        let key = "env|\(palette.isDark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let width = 256, height = 128
        guard let ctx = context(width: width, height: height) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Bottom of the image is the floor, top is the ceiling.
        let floorTone = palette.isDark
            ? CGColor(srgbRed: 0.020, green: 0.021, blue: 0.026, alpha: 1)
            : CGColor(srgbRed: 0.26, green: 0.26, blue: 0.26, alpha: 1)
        let horizon = palette.isDark
            ? CGColor(srgbRed: 0.062, green: 0.064, blue: 0.074, alpha: 1)
            : CGColor(srgbRed: 0.60, green: 0.60, blue: 0.61, alpha: 1)
        let ceiling = palette.isDark
            ? CGColor(srgbRed: 0.128, green: 0.126, blue: 0.130, alpha: 1)
            : CGColor(srgbRed: 0.84, green: 0.84, blue: 0.85, alpha: 1)

        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [floorTone, horizon, ceiling] as CFArray,
            locations: [0, 0.52, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: height),
                options: [])
        }

        // The strip light, as a soft bright band a little above the horizon.
        ctx.setFillColor(palette.shelfLight.copy(alpha: palette.isDark ? 0.22 : 0.14)
            ?? palette.shelfLight)
        ctx.fill(CGRect(x: 0, y: Int(Double(height) * 0.62), width: width, height: 9))

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Environment

    static func verticalGradient(top: CGColor, bottom: CGColor) -> CGImage? {
        let width = 4, height = 512
        guard let ctx = context(width: width, height: height) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [bottom, top] as CFArray,
            locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: [])
        return ctx.makeImage()
    }

    /// Quiet placeholder shown while cover art loads.
    static func placeholderCover(palette: AtriumPalette) -> CGImage? {
        let key = "placeholder|\(palette.isDark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let width = 200, height = 300
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(palette.placeholderBase)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let mark = CGRect(x: 78, y: 128, width: 44, height: 44)
        ctx.setStrokeColor(palette.placeholderMark)
        ctx.setLineWidth(3)
        ctx.stroke(mark)

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Artwork

    private static let sourceCache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 300
        return cache
    }()

    /// Snapshots a loaded platform image's backing CGImage, memoized per URL.
    /// AppKit/UIKit representation access is not thread-safe and `ImageLoader`
    /// shares one instance across callers, so this runs on the main actor —
    /// once per image — and everything downstream works from the immutable
    /// CGImage it returns.
    @MainActor
    static func sourceImage(for url: URL, from image: PlatformImage) -> CGImage? {
        if let hit = sourceCache.object(forKey: url as NSURL) { return hit }
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        #else
        let cgImage = image.cgImage
        #endif
        if let cgImage { sourceCache.setObject(cgImage, forKey: url as NSURL) }
        return cgImage
    }

    /// Resamples an immutable CGImage into a GPU-friendly bitmap, downscaling to
    /// `maxPixel` on the long edge so SceneKit uploads without a decode hitch
    /// during camera movement. With `aspect` (width/height) set, the source is
    /// center-cropped first so every poster fills its plane without distortion.
    static func resampled(_ image: CGImage, maxPixel: CGFloat, aspect: CGFloat? = nil) -> CGImage? {
        var source = image
        if let aspect, aspect > 0 {
            let w = CGFloat(source.width)
            let h = CGFloat(source.height)
            let sourceAspect = w / h
            if abs(sourceAspect - aspect) > 0.01 {
                let crop: CGRect
                if sourceAspect > aspect {
                    let cropWidth = h * aspect
                    crop = CGRect(x: (w - cropWidth) / 2, y: 0, width: cropWidth, height: h)
                } else {
                    let cropHeight = w / aspect
                    crop = CGRect(x: 0, y: (h - cropHeight) / 2, width: w, height: cropHeight)
                }
                source = source.cropping(to: crop.integral) ?? source
            }
        }
        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1, maxPixel / max(sourceWidth, sourceHeight))
        let width = max(1, Int(sourceWidth * scale))
        let height = max(1, Int(sourceHeight * scale))
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

