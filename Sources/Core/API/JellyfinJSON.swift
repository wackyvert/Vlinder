import Foundation

/// JSON configuration for the Jellyfin API.
///
/// Models carry explicit PascalCase `CodingKeys` (matching the server) rather than a
/// key-conversion strategy — a global strategy would also rewrite dictionary keys
/// (`ImageTags["Primary"]`, blurhash tags, provider ids) and silently break lookups.
///
/// Jellyfin emits ISO-8601 dates with up to 7 fractional digits
/// ("2024-01-01T12:00:00.0000000Z"), which Foundation's built-in ISO8601 strategies
/// reject, so dates go through a tolerant parser.
enum JellyfinJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return encoder
    }()

    /// Human-readable rendering of a DecodingError ("missing key 'X' at a.b.0").
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch (\(type)) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupt data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decodingError)
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ raw: String) -> Date? {
        // Truncate fractional seconds to 3 digits so ISO8601DateFormatter accepts them.
        var value = raw
        if let dotIndex = value.firstIndex(of: ".") {
            let fractionStart = value.index(after: dotIndex)
            var fractionEnd = fractionStart
            while fractionEnd < value.endIndex, value[fractionEnd].isNumber {
                fractionEnd = value.index(after: fractionEnd)
            }
            let fraction = value[fractionStart..<fractionEnd].prefix(3)
            value.replaceSubrange(dotIndex..<fractionEnd, with: fraction.isEmpty ? "" : ".\(fraction)")
        }
        if !value.hasSuffix("Z"), value.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) == nil {
            value += "Z"
        }
        return isoFractional.date(from: value) ?? isoPlain.date(from: value)
    }
}
