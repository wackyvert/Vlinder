import CoreGraphics
import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Generated textures for the Live TV wall. CoreGraphics/CoreText only, safe to
// run off the main thread, returning CGImage for SceneKit materials.
//
// The wall's look is a lit room rather than the library's cinema void: every
// card is a small screen that emits its own light, so the chrome is drawn to be
// seen — a red LIVE tab, a channel number set large enough to read at a glance,
// and a band-coloured edge that says which kind of television you are looking
// at without anyone having to read the plate.

/// Live TV wall colours. Bands are told apart by accent, so the eye can find
/// its way back to Sports without reading a word.
struct LiveWallPalette: Equatable {
    var isDark: Bool

    var voidTop: CGColor
    var voidBottom: CGColor
    var floor: CGColor
    var cardGround: CGColor
    var ink: CGColor
    var inkDim: CGColor
    var scrim: CGColor
    var progressTrack: CGColor
    var liveBadge: CGColor
    var plateGlass: CGColor

    /// Band accents, taken in order. Cool through warm, all of them able to
    /// hold a thin bright line against a near-black room.
    var accents: [CGColor]

    func accent(_ index: Int) -> CGColor {
        guard !accents.isEmpty else { return CGColor(srgbRed: 0.36, green: 0.62, blue: 1, alpha: 1) }
        return accents[((index % accents.count) + accents.count) % accents.count]
    }

    static func palette(dark: Bool) -> LiveWallPalette {
        LiveWallPalette(
            isDark: dark,
            voidTop: CGColor(srgbRed: 0.016, green: 0.020, blue: 0.055, alpha: 1),
            voidBottom: CGColor(srgbRed: 0.006, green: 0.008, blue: 0.024, alpha: 1),
            floor: CGColor(srgbRed: 0.020, green: 0.024, blue: 0.052, alpha: 1),
            cardGround: CGColor(srgbRed: 0.085, green: 0.098, blue: 0.165, alpha: 1),
            ink: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98),
            inkDim: CGColor(srgbRed: 0.80, green: 0.84, blue: 0.95, alpha: 0.75),
            scrim: CGColor(srgbRed: 0.010, green: 0.014, blue: 0.038, alpha: 1),
            progressTrack: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
            liveBadge: CGColor(srgbRed: 0.898, green: 0.180, blue: 0.180, alpha: 1),
            plateGlass: CGColor(srgbRed: 0.052, green: 0.074, blue: 0.176, alpha: 1),
            accents: [
                CGColor(srgbRed: 0.259, green: 0.706, blue: 1.000, alpha: 1),   // cyan — news
                CGColor(srgbRed: 0.318, green: 0.522, blue: 1.000, alpha: 1),   // blue — sports
                CGColor(srgbRed: 0.635, green: 0.361, blue: 1.000, alpha: 1),   // violet — movies
                CGColor(srgbRed: 1.000, green: 0.616, blue: 0.235, alpha: 1),   // amber
                CGColor(srgbRed: 0.239, green: 0.867, blue: 0.667, alpha: 1),   // mint
                CGColor(srgbRed: 1.000, green: 0.373, blue: 0.612, alpha: 1),   // rose
            ])
    }
}

enum LiveWallTextures {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 500
        return cache
    }()

    static func flushCache() {
        cache.removeAllObjects()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
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

    private static func line(
        _ text: String, font: PlatformFont, color: CGColor, tracking: CGFloat = 0
    ) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if tracking != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func truncated(
        _ text: String, font: PlatformFont, color: CGColor, width limit: CGFloat
    ) -> CTLine {
        let full = line(text, font: font, color: color)
        guard width(of: full) > limit else { return full }
        let token = line("…", font: font, color: color)
        return CTLineCreateTruncatedLine(full, Double(limit), .end, token) ?? full
    }

    private static func draw(_ line: CTLine, in ctx: CGContext, at point: CGPoint) {
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    // MARK: - The card face

    /// One channel's card: the programme's picture, a scrim across its foot,
    /// and the chrome that says what it is — LIVE, the channel number, the
    /// title, how far through it is, and (on the card being looked at) the
    /// hour it runs.
    ///
    /// `emphasis` is the card under the eye: it is drawn larger in its own
    /// frame as well as scaled up in the room, the way a focused tile on a real
    /// ten-foot interface has to be, and it carries the times and a lit edge.
    static func cardFace(
        card: LiveWallCard,
        art: CGImage?,
        accent: CGColor,
        palette: LiveWallPalette,
        emphasis: Bool,
        maxPixel: CGFloat = 1024
    ) -> CGImage? {
        let w = Int(maxPixel)
        let h = Int(maxPixel * 9 / 16)
        guard let ctx = context(width: w, height: h) else { return nil }

        let width = CGFloat(w)
        let height = CGFloat(h)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = width * 0.032

        ctx.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(clip)
        ctx.clip()

        // Ground first, so a card with no still is still a card and not a hole.
        ctx.setFillColor(palette.cardGround)
        ctx.fill(rect)

        if let art, !card.artworkIsLogo,
           let framed = resampled(art, maxPixel: width * 1.05, aspect: width / height) {
            // A still of the programme is the picture: fill the card with it.
            ctx.draw(framed, in: rect)
        } else if let art {
            // A channel logo is a mark, not a picture. Cropping it to fill the
            // card cuts the mark in half — which is exactly what a channel logo
            // must never be — so it is shown whole, over a soft blown-up copy
            // of itself that gives the card a picture to be rather than a mark
            // floating in an empty box.
            drawLogo(art, in: ctx, rect: rect, accent: accent, palette: palette, emphasis: emphasis)
        } else {
            drawEmptyGround(in: ctx, rect: rect, accent: accent, palette: palette)
        }

        // Television is lit brighter than print: hold it back a touch so the
        // white chrome on top of it stays the brightest thing on the card.
        ctx.setFillColor(CGColor(gray: 0, alpha: emphasis ? 0.04 : 0.09))
        ctx.fill(rect)

        drawFootScrim(in: ctx, rect: rect, palette: palette, tall: emphasis)

        let inset = width * (emphasis ? 0.048 : 0.055)
        drawLiveBadge(
            in: ctx, rect: rect, inset: inset, palette: palette,
            scale: emphasis ? 1.15 : 0.80, spelled: emphasis)

        drawFootMatter(
            card: card, in: ctx, rect: rect, inset: inset,
            accent: accent, palette: palette, emphasis: emphasis)

        ctx.restoreGState()

        drawEdge(in: ctx, rect: rect, radius: radius, accent: accent, emphasis: emphasis, width: width)

        return ctx.makeImage()
    }

    /// A channel logo, shown whole and centred on a ground taken from the logo
    /// itself. The mark sits high on the card so the chrome along the foot has
    /// somewhere to go.
    private static func drawLogo(
        _ art: CGImage, in ctx: CGContext, rect: CGRect, accent: CGColor,
        palette: LiveWallPalette, emphasis: Bool
    ) {
        let tint = SpatialTextures.spineTint(from: art)
        let ground = tint.map { mix($0, into: palette.cardGround, amount: 0.52) } ?? palette.cardGround
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [lifted(ground, amount: 0.24), mix(ground, into: palette.cardGround, amount: 0.42)] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            ctx.setFillColor(ground)
            ctx.fill(rect)
        }

        let sourceAspect = CGFloat(art.width) / CGFloat(max(1, art.height))
        ctx.interpolationQuality = .high

        // The mark itself, crisp, sitting high so the foot belongs to the chrome.
        let boxWidth = rect.width * (emphasis ? 0.62 : 0.56)
        let boxHeight = rect.height * (emphasis ? 0.52 : 0.46)
        var drawn = CGSize(width: boxWidth, height: boxWidth / sourceAspect)
        if drawn.height > boxHeight {
            drawn = CGSize(width: boxHeight * sourceAspect, height: boxHeight)
        }
        ctx.draw(art, in: CGRect(
            x: rect.midX - drawn.width / 2,
            y: rect.minY + rect.height * 0.63 - drawn.height / 2,
            width: drawn.width, height: drawn.height))
    }

    /// A card whose programme has no still: the channel number stands in for
    /// the picture, on a ground mixed from the band's own accent.
    private static func drawEmptyGround(
        in ctx: CGContext, rect: CGRect, accent: CGColor, palette: LiveWallPalette
    ) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                mix(accent, into: palette.cardGround, amount: 0.30),
                palette.cardGround,
            ] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// The dark wash the chrome is set on, so a bright still never swallows the
    /// title. Taller on the focused card, which carries more print.
    private static func drawFootScrim(
        in ctx: CGContext, rect: CGRect, palette: LiveWallPalette, tall: Bool
    ) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ground = palette.scrim
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                ground.copy(alpha: tall ? 0.94 : 0.90) ?? ground,
                ground.copy(alpha: tall ? 0.74 : 0.66) ?? ground,
                ground.copy(alpha: 0) ?? ground,
            ] as CFArray,
            locations: [0, 0.42, 1])
        else { return }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.minY),
            end: CGPoint(x: 0, y: rect.minY + rect.height * (tall ? 0.62 : 0.54)),
            options: [])
    }

    /// The red tab. Squared-off and small, the way a broadcaster's is — it is a
    /// state, not a button.
    private static func drawLiveBadge(
        in ctx: CGContext, rect: CGRect, inset: CGFloat, palette: LiveWallPalette,
        scale: CGFloat, spelled: Bool
    ) {
        // Away from the focus the word is unreadable anyway and forty of them
        // shouting at once is noise — the tab shrinks to the dot it would read
        // as from the sofa.
        guard spelled else {
            let dot = rect.width * 0.020
            ctx.addEllipse(in: CGRect(
                x: rect.minX + inset, y: rect.maxY - inset - dot * 2,
                width: dot * 2, height: dot * 2))
            ctx.setFillColor(palette.liveBadge)
            ctx.fillPath()
            return
        }

        let font = systemFont(size: rect.width * 0.043 * scale, weight: .heavy)
        let text = line("LIVE", font: font, color: CGColor(gray: 1, alpha: 1), tracking: rect.width * 0.0035)
        let padX = rect.width * 0.022 * scale
        let padY = rect.width * 0.014 * scale
        let badgeWidth = width(of: text) + padX * 2
        let badgeHeight = font.ascender - font.descender + padY * 2
        let badgeRect = CGRect(
            x: rect.minX + inset,
            y: rect.maxY - inset - badgeHeight,
            width: badgeWidth,
            height: badgeHeight)

        let corner = badgeHeight * 0.24
        ctx.addPath(CGPath(
            roundedRect: badgeRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(palette.liveBadge)
        ctx.fillPath()

        draw(text, in: ctx, at: CGPoint(
            x: badgeRect.minX + padX,
            y: badgeRect.minY + padY - font.descender))
    }

    /// Channel number, title, progress and hours — everything that lives along
    /// the foot of the card.
    private static func drawFootMatter(
        card: LiveWallCard,
        in ctx: CGContext,
        rect: CGRect,
        inset: CGFloat,
        accent: CGColor,
        palette: LiveWallPalette,
        emphasis: Bool
    ) {
        let span = rect.width
        let numberFont = systemFont(size: span * (emphasis ? 0.086 : 0.070), weight: .bold)
        let titleFont = systemFont(size: span * (emphasis ? 0.078 : 0.062), weight: .semibold)
        let timeFont = systemFont(size: span * (emphasis ? 0.040 : 0.032), weight: .medium)

        // The hours sit at the right of the same line as the bar, so the bar
        // has to stop short of them.
        var timesLine: CTLine?
        var timesWidth: CGFloat = 0
        if emphasis, let start = card.startLabel, let end = card.endLabel {
            let text = line("\(start) / \(end)", font: timeFont, color: palette.inkDim)
            timesLine = text
            timesWidth = self.width(of: text) + inset * 0.8
        }

        let barHeight = span * (emphasis ? 0.013 : 0.010)
        let barY = rect.minY + inset * (emphasis ? 1.15 : 1.0)
        let titleBaseline = barY + barHeight + span * (emphasis ? 0.028 : 0.022) - titleFont.descender

        // The number is set on the title's baseline, big and held back, so it
        // reads as a channel marking rather than as part of the programme name.
        let numberText = card.channelNumber.isEmpty ? nil : line(
            card.channelNumber, font: numberFont,
            color: CGColor(gray: 1, alpha: emphasis ? 0.42 : 0.36))
        var titleX = rect.minX + inset
        if let numberText {
            draw(numberText, in: ctx, at: CGPoint(x: titleX, y: titleBaseline))
            titleX += self.width(of: numberText) + span * 0.022
        }

        let titleLimit = rect.maxX - inset - titleX - (emphasis ? 0 : span * 0.01)
        let title = truncated(card.title, font: titleFont, color: palette.ink, width: max(1, titleLimit))
        draw(title, in: ctx, at: CGPoint(x: titleX, y: titleBaseline))

        if let timesLine {
            draw(timesLine, in: ctx, at: CGPoint(
                x: rect.maxX - inset - self.width(of: timesLine),
                y: barY - timeFont.descender - barHeight * 0.4))
        }

        // The bar runs from the title's own left edge, not the card's, so the
        // number and the bar share a margin and the foot reads as one block.
        let barRect = CGRect(
            x: titleX,
            y: barY,
            width: max(0, rect.maxX - inset - titleX - timesWidth),
            height: barHeight)
        drawProgress(
            in: ctx, rect: barRect, fraction: card.progress,
            accent: accent, palette: palette, emphasis: emphasis)
    }

    private static func drawProgress(
        in ctx: CGContext,
        rect: CGRect,
        fraction: Double?,
        accent: CGColor,
        palette: LiveWallPalette,
        emphasis: Bool
    ) {
        // A track with nothing in it is a horizontal rule, not an indicator.
        // Where there is no programme there is nothing to report, so nothing
        // is drawn.
        guard rect.width > 0, let fraction, fraction > 0 else { return }
        let radius = rect.height / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(palette.progressTrack)
        ctx.fillPath()

        let filled = CGRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.height, rect.width * CGFloat(min(fraction, 1))),
            height: rect.height)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil))
        // The focused card's bar is the one thing on the wall allowed to be
        // pure white — it is the "now" reading.
        ctx.setFillColor(emphasis
            ? CGColor(gray: 1, alpha: 0.96)
            : mix(accent, into: CGColor(gray: 1, alpha: 1), amount: 0.55))
        ctx.fillPath()
    }

    /// The lit edge. Unfocused cards get a hairline so the wall reads as tiles;
    /// the focused one gets a bright band with the glow bled inward, which is
    /// what a real display's bezel light does to its own picture.
    private static func drawEdge(
        in ctx: CGContext,
        rect: CGRect,
        radius: CGFloat,
        accent: CGColor,
        emphasis: Bool,
        width cardWidth: CGFloat
    ) {
        if emphasis {
            for step in 0..<4 {
                let inset = cardWidth * (0.004 + CGFloat(step) * 0.007)
                let alpha = 0.34 / CGFloat(step + 1)
                let path = CGPath(
                    roundedRect: rect.insetBy(dx: inset, dy: inset),
                    cornerWidth: max(1, radius - inset), cornerHeight: max(1, radius - inset),
                    transform: nil)
                ctx.addPath(path)
                ctx.setStrokeColor(accent.copy(alpha: alpha) ?? accent)
                ctx.setLineWidth(cardWidth * 0.010)
                ctx.strokePath()
            }
        }

        let lineWidth = cardWidth * (emphasis ? 0.0075 : 0.0028)
        let inset = lineWidth / 2
        ctx.addPath(CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(emphasis
            ? lifted(accent, amount: 0.45)
            : accent.copy(alpha: 0.34) ?? accent)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }

    // MARK: - The band plate

    /// The plate at the head of a band: a pane of tinted glass carrying the
    /// group's glyph and name. It is the only place on the wall that says a
    /// word about categories, so it is allowed to be plain.
    static func groupPlate(
        name: String,
        kicker: String? = nil,
        symbolName: String,
        accent: CGColor,
        palette: LiveWallPalette,
        emphasis: Bool,
        maxPixel: CGFloat = 620
    ) -> CGImage? {
        let key = "plate|\(name)|\(kicker ?? "")|\(symbolName)|\(emphasis)|\(palette.isDark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let w = Int(maxPixel)
        let h = Int(maxPixel * 0.92)
        guard let ctx = context(width: w, height: h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let radius = rect.width * 0.075

        let path = CGPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(palette.plateGlass)
        ctx.fill(rect)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                mix(accent, into: palette.plateGlass, amount: emphasis ? 0.30 : 0.14),
                palette.plateGlass,
            ] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(accent.copy(alpha: emphasis ? 0.85 : 0.34) ?? accent)
        ctx.setLineWidth(rect.width * (emphasis ? 0.010 : 0.005))
        ctx.strokePath()

        let glyphSide = rect.width * 0.30
        if let glyph = symbol(named: symbolName, pointSize: glyphSide, weight: .medium) {
            let aspect = CGFloat(glyph.width) / CGFloat(max(1, glyph.height))
            let drawn = CGSize(width: glyphSide * aspect, height: glyphSide)
            let glyphRect = CGRect(
                x: rect.midX - drawn.width / 2,
                y: rect.midY + rect.height * 0.08,
                width: drawn.width, height: drawn.height)
            ctx.saveGState()
            ctx.clip(to: glyphRect, mask: glyph)
            ctx.setFillColor(emphasis ? lifted(accent, amount: 0.30) : accent.copy(alpha: 0.72) ?? accent)
            ctx.fill(glyphRect)
            ctx.restoreGState()
        }

        // The plate's whole job is to name the band, so the name never gets
        // truncated — a long one wraps onto a second line instead.
        let ink = emphasis ? palette.ink : palette.inkDim
        // Every plate sets its name at the same size, whatever the name is —
        // three categories at three sizes never read as one rail. A name too
        // long for the width breaks across two lines instead of shrinking.
        let font = systemFont(size: rect.width * 0.132, weight: .semibold)
        let lines = wrapAny(name, font: font, color: ink, width: rect.width * 0.86)
        let lineHeight = font.ascender - font.descender
        var baseline = rect.midY - rect.height * 0.17
            + (lines.count > 1 ? lineHeight * 0.42 : 0)
        for text in lines {
            draw(text, in: ctx, at: CGPoint(x: rect.midX - width(of: text) / 2, y: baseline))
            baseline -= lineHeight * 0.92
        }

        if let kicker {
            let kickerFont = systemFont(size: rect.width * 0.072, weight: .medium)
            let text = truncated(
                kicker.uppercased(), font: kickerFont,
                color: (emphasis ? palette.inkDim : palette.inkDim).copy(alpha: 0.60) ?? palette.inkDim,
                width: rect.width * 0.88)
            draw(text, in: ctx, at: CGPoint(
                x: rect.midX - width(of: text) / 2,
                y: rect.midY - rect.height * 0.30))
        }

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Breaks a label across up to two lines at the best point — at a space
    /// where there is one, mid-word where there is not — so the type size can
    /// stay fixed across the rail.
    private static func wrapAny(
        _ text: String, font: PlatformFont, color: CGColor, width limit: CGFloat
    ) -> [CTLine] {
        let single = line(text, font: font, color: color)
        if width(of: single) <= limit { return [single] }
        if text.contains(" ") { return wrapTwo(text, font: font, color: color, width: limit) }

        // One long word: break it where it stops fitting, and hyphenate.
        var head = ""
        for character in text {
            let candidate = head + String(character) + "-"
            if width(of: line(candidate, font: font, color: color)) > limit { break }
            head.append(character)
        }
        guard !head.isEmpty, head.count < text.count else {
            return [truncated(text, font: font, color: color, width: limit)]
        }
        let tail = String(text.dropFirst(head.count))
        return [
            line(head + "-", font: font, color: color),
            truncated(tail, font: font, color: color, width: limit),
        ]
    }

    /// Sets a label on one line, or on two broken at the best word, before it
    /// will accept being cut short.
    private static func wrapTwo(
        _ text: String, font: PlatformFont, color: CGColor, width limit: CGFloat
    ) -> [CTLine] {
        let single = line(text, font: font, color: color)
        if width(of: single) <= limit { return [single] }

        let words = text.split(separator: " ")
        guard words.count > 1 else { return [truncated(text, font: font, color: color, width: limit)] }

        var best: (head: String, tail: String, worst: CGFloat)?
        for split in 1..<words.count {
            let head = words[..<split].joined(separator: " ")
            let tail = words[split...].joined(separator: " ")
            let worst = max(
                width(of: line(head, font: font, color: color)),
                width(of: line(tail, font: font, color: color)))
            if best == nil || worst < best!.worst {
                best = (head, tail, worst)
            }
        }
        guard let best else { return [single] }
        return [
            truncated(best.head, font: font, color: color, width: limit),
            truncated(best.tail, font: font, color: color, width: limit),
        ]
    }

    // MARK: - The clock

    /// The time reading that hangs over the wall, with the stalk that drops
    /// from it toward the card being looked at.
    static func timeMarker(
        label: String, palette: LiveWallPalette, accent: CGColor, maxPixel: CGFloat = 420
    ) -> CGImage? {
        let key = "time|\(label)|\(palette.isDark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let w = Int(maxPixel)
        let h = Int(maxPixel * 0.5)
        guard let ctx = context(width: w, height: h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        let font = systemFont(size: rect.width * 0.19, weight: .medium)
        let text = line(label, font: font, color: palette.ink)
        draw(text, in: ctx, at: CGPoint(
            x: rect.midX - width(of: text) / 2,
            y: rect.maxY - rect.height * 0.30 - font.ascender))

        // Stalk and bead: the wall's one piece of instrumentation.
        let stalkTop = rect.maxY - rect.height * 0.44
        ctx.setStrokeColor(accent.copy(alpha: 0.55) ?? accent)
        ctx.setLineWidth(max(1, rect.width * 0.006))
        ctx.move(to: CGPoint(x: rect.midX, y: stalkTop))
        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.10))
        ctx.strokePath()

        let bead = rect.width * 0.022
        ctx.addEllipse(in: CGRect(
            x: rect.midX - bead, y: stalkTop - bead, width: bead * 2, height: bead * 2))
        ctx.setFillColor(lifted(accent, amount: 0.40))
        ctx.fillPath()

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The light line that separates one band from the next: brightest at the
    /// centre of the view and running out to nothing at both ends, so the wall
    /// has no visible edge.
    static func separatorLine(
        accent: CGColor, emphasis: Bool, maxPixel: CGFloat = 2048
    ) -> CGImage? {
        let key = "sep|\(emphasis)|\(accent.components?.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let w = Int(maxPixel)
        let h = 64
        guard let ctx = context(width: w, height: h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Vertical: a hot core with the glow falling away above and below.
        if let bloom = CGGradient(
            colorsSpace: space,
            colors: [
                accent.copy(alpha: 0) ?? accent,
                accent.copy(alpha: emphasis ? 0.62 : 0.40) ?? accent,
                lifted(accent, amount: 1.0),
                accent.copy(alpha: emphasis ? 0.62 : 0.40) ?? accent,
                accent.copy(alpha: 0) ?? accent,
            ] as CFArray,
            locations: [0, 0.42, 0.5, 0.58, 1]) {
            ctx.drawLinearGradient(
                bloom,
                start: CGPoint(x: 0, y: rect.minY),
                end: CGPoint(x: 0, y: rect.maxY),
                options: [])
        }
        // Horizontal: fade both ends into the room.
        ctx.setBlendMode(.destinationIn)
        if let fade = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(gray: 0, alpha: 0),
                CGColor(gray: 0, alpha: 0.34),
                CGColor(gray: 0, alpha: 1),
                CGColor(gray: 0, alpha: 0.34),
                CGColor(gray: 0, alpha: 0),
            ] as CFArray,
            locations: [0, 0.10, 0.5, 0.90, 1]) {
            ctx.drawLinearGradient(
                fade,
                start: CGPoint(x: rect.minX, y: 0),
                end: CGPoint(x: rect.maxX, y: 0),
                options: [])
        }
        ctx.setBlendMode(.normal)

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Soft rectangular bloom laid behind the focused card, so its light
    /// spills onto the wall around it rather than stopping at its edge.
    static func cardGlow(accent: CGColor, maxPixel: CGFloat = 512) -> CGImage? {
        let key = "glow|\(accent.components?.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let w = Int(maxPixel)
        let h = Int(maxPixel * 9 / 16)
        guard let ctx = context(width: w, height: h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        // Built by stacking increasingly inset rounded rects: cheap, and it
        // keeps the bloom the shape of the card rather than a circle.
        let steps = 22
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)
            // Squared easing: most of the light sits close to the card's edge
            // and only a little of it reaches out onto the wall.
            let inset = rect.width * 0.34 * (t * t)
            let radius = rect.width * 0.09
            ctx.addPath(CGPath(
                roundedRect: rect.insetBy(dx: inset, dy: inset * (rect.height / rect.width)),
                cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(accent.copy(alpha: 0.013) ?? accent)
            ctx.fillPath()
        }

        // Whatever the stack left at the plane's border would show as a hard
        // rectangular seam on the wall, so the whole thing is masked by a
        // radial falloff that is genuinely zero before the edge.
        ctx.setBlendMode(.destinationIn)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let mask = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(gray: 0, alpha: 1),
                CGColor(gray: 0, alpha: 1),
                CGColor(gray: 0, alpha: 0),
            ] as CFArray,
            locations: [0, 0.30, 1]) {
            ctx.saveGState()
            // Squashed to the card's proportions so the falloff is elliptical
            // rather than circular on a wide card.
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: 1, y: rect.height / rect.width)
            ctx.drawRadialGradient(
                mask,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: rect.width / 2,
                options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Room

    /// Vertical wash for the room behind the wall.
    static func roomBackground(palette: LiveWallPalette) -> CGImage? {
        let key = "room|\(palette.isDark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let w = 512, h = 288
        guard let ctx = context(width: w, height: h) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ctx.setFillColor(palette.voidBottom)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // The room is lit from the middle, where the wall is — a flat black
        // ground gives the cards nothing to be in front of.
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [palette.voidTop, palette.voidBottom] as CFArray,
            locations: [0, 1])
        else { return nil }
        let centre = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.56)
        ctx.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(w) * 0.62,
            options: [.drawsAfterEndLocation])

        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Helpers

    /// SF Symbol rendered to a mask-able image.
    static func symbol(named name: String, pointSize: CGFloat, weight: PlatformFontWeight) -> CGImage? {
        #if os(macOS)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let image = symbol.withSymbolConfiguration(config)
        else { return nil }
        var frame = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &frame, context: nil, hints: nil)
        #else
        // A font carries both the size and the weight, and UIKit maps the
        // weight onto the symbol's own scale.
        let config = UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: pointSize, weight: weight))
        return UIImage(systemName: name, withConfiguration: config)?.cgImage
        #endif
    }

    static func mix(_ color: CGColor, into ground: CGColor, amount: CGFloat) -> CGColor {
        guard let a = color.components, a.count >= 3,
              let b = ground.components, b.count >= 3
        else { return ground }
        let t = min(max(amount, 0), 1)
        return CGColor(
            srgbRed: b[0] + (a[0] - b[0]) * t,
            green: b[1] + (a[1] - b[1]) * t,
            blue: b[2] + (a[2] - b[2]) * t,
            alpha: (b.count >= 4 ? b[3] : 1))
    }

    /// Pushes a colour toward white without washing out its hue — what a
    /// saturated accent looks like where it is brightest.
    static func lifted(_ color: CGColor, amount: CGFloat) -> CGColor {
        guard let c = color.components, c.count >= 3 else { return color }
        let t = min(max(amount, 0), 1)
        return CGColor(
            srgbRed: c[0] + (1 - c[0]) * t,
            green: c[1] + (1 - c[1]) * t,
            blue: c[2] + (1 - c[2]) * t,
            alpha: c.count >= 4 ? c[3] : 1)
    }

    /// Centre-crops and resamples artwork to the requested aspect.
    static func resampled(_ image: CGImage, maxPixel: CGFloat, aspect: CGFloat) -> CGImage? {
        let targetWidth = Int(maxPixel)
        let targetHeight = max(1, Int(maxPixel / aspect))
        guard let ctx = context(width: targetWidth, height: targetHeight) else { return nil }

        let sourceAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var drawRect = CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight))
        if sourceAspect > aspect {
            // Source is wider: overflow the sides.
            let width = CGFloat(targetHeight) * sourceAspect
            drawRect = CGRect(
                x: (CGFloat(targetWidth) - width) / 2, y: 0,
                width: width, height: CGFloat(targetHeight))
        } else if sourceAspect < aspect {
            let height = CGFloat(targetWidth) / sourceAspect
            drawRect = CGRect(
                x: 0, y: (CGFloat(targetHeight) - height) / 2,
                width: CGFloat(targetWidth), height: height)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        return ctx.makeImage()
    }

    static func sourceImage(for url: URL, from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var frame = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &frame, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }
}
