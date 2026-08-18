import Foundation

// Channel lineup (external categorization) — verbatim port of Tuner's
// Shared/Models.swift ChannelLineup + Lineup/LineupParser.swift, which are
// themselves line-for-line ports of Fladder's lib/models/live_tv_lineup.dart.
// All three apps point at the same relay; the lineup URL format is the
// cross-app contract, quirks included. Do not "clean up" the parsing.

struct ChannelLineup: Equatable {
    /// Group names in original lineup order.
    var groupOrder: [String]
    var groupByNumber: [String: String]
    var groupByName: [String: String]
    /// Position of each entry in the source document, so the guide can present
    /// channels in the provider's own order rather than by channel number.
    var orderByNumber: [String: Int]
    var orderByName: [String: Int]
    var entryCount: Int

    var isEmpty: Bool { groupOrder.isEmpty }

    func group(forNumber number: String?, name: String) -> String? {
        if let number, let byNumber = groupByNumber[Self.normalizeNumber(number)] {
            return byNumber
        }
        return groupByName[Self.normalizeName(name)]
    }

    /// Position in the source document; nil when the channel isn't in the
    /// lineup. Number-first then name, matching `group(forNumber:name:)`.
    func order(forNumber number: String?, name: String) -> Int? {
        if let number, let byNumber = orderByNumber[Self.normalizeNumber(number)] {
            return byNumber
        }
        return orderByName[Self.normalizeName(name)]
    }

    /// "5.0" → "5", " 62.1 " → "62.1", non-numeric passes through trimmed.
    static func normalizeNumber(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return trimmed }
        if value == value.rounded(.towardZero), value.magnitude < 1e15 {
            return String(Int(value))
        }
        return "\(value)"
    }

    static func normalizeName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct LineupEntry {
    var name: String
    var group: String
    var number: String?
    var tvgId: String?
}

extension ChannelLineup {
    /// Parses `content` as either an M3U playlist or a lineup JSON document.
    /// Returns nil when the content is neither.
    static func parse(_ content: String) -> ChannelLineup? {
        let trimmed = LineupText.trim(content)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("#EXTM3U") || trimmed.hasPrefix("#EXTINF") {
            return parseM3U(trimmed)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return parseJSON(trimmed)
        }
        return nil
    }

    /// Builds the lookup tables from raw entries. Dart semantics:
    /// - entries whose trimmed group is empty are skipped (and not counted)
    /// - `groupOrder` is first-appearance order of trimmed group names
    /// - number/name keys are normalized and inserted first-wins (putIfAbsent)
    static func fromEntries(_ entries: [LineupEntry]) -> ChannelLineup {
        var groupOrder: [String] = []
        var seenGroups: Set<String> = []
        var groupByNumber: [String: String] = [:]
        var groupByName: [String: String] = [:]
        var orderByNumber: [String: Int] = [:]
        var orderByName: [String: Int] = [:]
        var count = 0

        for entry in entries {
            let group = LineupText.trim(entry.group)
            if group.isEmpty { continue }
            let position = count
            count += 1
            if seenGroups.insert(group).inserted {
                groupOrder.append(group)
            }
            if let number = entry.number, !LineupText.trim(number).isEmpty {
                let key = ChannelLineup.normalizeNumber(number)
                if groupByNumber[key] == nil { groupByNumber[key] = group }
                if orderByNumber[key] == nil { orderByNumber[key] = position }
            }
            if !LineupText.trim(entry.name).isEmpty {
                let key = ChannelLineup.normalizeName(entry.name)
                if groupByName[key] == nil { groupByName[key] = group }
                if orderByName[key] == nil { orderByName[key] = position }
            }
        }

        return ChannelLineup(
            groupOrder: groupOrder,
            groupByNumber: groupByNumber,
            groupByName: groupByName,
            orderByNumber: orderByNumber,
            orderByName: orderByName,
            entryCount: count)
    }

    // MARK: - M3U

    private static func parseM3U(_ content: String) -> ChannelLineup {
        var entries: [LineupEntry] = []
        // Dart splits on \r?\n (lone \r is NOT a line break there either).
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            let trimmedLine = LineupText.trim(line)
            guard trimmedLine.range(
                of: "^#EXTINF:",
                options: [.regularExpression, .caseInsensitive]
            ) != nil else { continue }

            // Attributes come from the RAW line; keys lowercased; a duplicate
            // key keeps the LAST value (Dart map-literal semantics).
            var attributes: [String: String] = [:]
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            for match in LineupText.attributePattern.matches(in: line, range: fullRange) {
                let key = nsLine.substring(with: match.range(at: 1)).lowercased()
                attributes[key] = nsLine.substring(with: match.range(at: 2))
            }

            // Display name is everything after the LAST comma on the raw line.
            let displayName: String
            if let commaRange = line.range(of: ",", options: .backwards) {
                displayName = LineupText.trim(String(line[commaRange.upperBound...]))
            } else {
                displayName = ""
            }

            // Raw (untrimmed) emptiness check, exactly like Dart; fromEntries
            // re-trims, so a whitespace-only group still gets dropped there.
            let group = attributes["group-title"] ?? ""
            if group.isEmpty { continue }

            entries.append(
                LineupEntry(
                    name: !displayName.isEmpty ? displayName : (attributes["tvg-name"] ?? ""),
                    group: group,
                    number: attributes["tvg-chno"] ?? attributes["channel-number"],
                    tvgId: attributes["tvg-id"]))
        }
        return fromEntries(entries)
    }

    // MARK: - JSON

    private static func parseJSON(_ content: String) -> ChannelLineup {
        guard
            let data = content.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
        else {
            // Dart returns fromEntries([]) when jsonDecode throws.
            return fromEntries([])
        }

        let list: [Any]
        if let array = decoded as? [Any] {
            list = array
        } else if let object = decoded as? [String: Any] {
            list = object["channels"] as? [Any] ?? []
        } else {
            list = []
        }

        var entries: [LineupEntry] = []
        for item in list {
            guard let item = item as? [String: Any] else { continue }
            let group = LineupJSON.string(item["group"])
                ?? LineupJSON.string(item["groupTitle"])
                ?? ""
            let name = LineupJSON.string(item["name"]) ?? ""
            let number = LineupJSON.string(item["number"])
                ?? LineupJSON.string(item["channelNumber"])
            entries.append(
                LineupEntry(
                    name: name,
                    group: group,
                    number: number,
                    tvgId: LineupJSON.string(item["tvgId"])))
        }
        return fromEntries(entries)
    }
}

// MARK: - Text helpers

enum LineupText {
    /// Dart's `String.trim()` strips Unicode White_Space PLUS U+FEFF (BOM);
    /// `.whitespacesAndNewlines` alone misses the BOM, which real-world M3U
    /// payloads do lead with.
    static let trimSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(Unicode.Scalar(0xFEFF)!)
        return set
    }()

    static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: trimSet)
    }

    /// Dart: `([a-zA-Z0-9-]+)="([^"]*)"`
    static let attributePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z0-9-]+)="([^"]*)""#)
}

// MARK: - JSON value stringification (Dart `toString()` parity)

enum LineupJSON {
    /// Dart-style `value?.toString()`: nil for missing values and JSON null,
    /// otherwise a string form matching Dart's `toString()` for the types a
    /// lineup document can contain (String, int, double, bool).
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            switch String(cString: number.objCType) {
            case "c", "C", "s", "S", "i", "I", "l", "L", "q":
                return String(number.int64Value)
            case "Q":
                return String(number.uint64Value)
            default:
                return String(number.doubleValue)
            }
        }
        return String(describing: value)
    }
}
