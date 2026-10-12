import Foundation

/// Turns a spoken title into something playable.
///
/// Shared by the App Intents and the `INPlayMediaIntent` handler so "play The
/// Bear on Vlinder" resolves identically whichever grammar Siri routes it
/// through. Returns *all* plausible matches ranked, never a single guess: the
/// callers disambiguate rather than picking for the user.
struct MediaResolver {
    enum Match: Equatable {
        case item(BaseItem)
        case channel(BaseItem)

        var id: String {
            switch self {
            case .item(let i), .channel(let i): return i.id
            }
        }

        var title: String {
            switch self {
            case .item(let i): return i.displayTitle
            case .channel(let c): return c.displayTitle
            }
        }

        var link: DeepLink {
            switch self {
            case .item(let i): return .play(itemId: i.id)
            case .channel(let c): return .tune(channelId: c.id)
            }
        }
    }

    /// A match plus how well it matched, so callers can tell "one obvious
    /// answer" from "several equally good ones" instead of guessing.
    struct Ranked: Equatable {
        var score: Int
        var match: Match
    }

    let client: JellyfinClient

    /// Library first, then live channels — "play CNN" should reach the channel,
    /// but a spoken show title must not be shadowed by a channel of the same
    /// name that merely contains the words.
    func resolve(spoken: String, includeChannels: Bool = true) async -> [Ranked] {
        let needle = Self.normalize(spoken)
        guard !needle.isEmpty else { return [] }

        var scored: [Ranked] = []

        if let result = try? await client.items(itemsQuery(searchTerm: spoken)) {
            for item in result.items ?? [] {
                guard let score = Self.score(needle: needle, candidates: [item.displayTitle, item.originalTitle, item.seriesName]) else { continue }
                scored.append(Ranked(score: score, match: .item(item)))
            }
        }

        if includeChannels, let channels = try? await client.liveTvChannels() {
            for channel in channels {
                // Call sign and channel number are how people actually say a
                // channel out loud ("play ESPN", "play channel 704").
                let candidates = [channel.displayTitle, channel.channelNumber, channel.number]
                guard let score = Self.score(needle: needle, candidates: candidates) else { continue }
                scored.append(Ranked(score: score, match: .channel(channel)))
            }
        }

        return scored.sorted { $0.score > $1.score }
    }

    /// "resume <show> on Vlinder" — restricted to what the server says is
    /// actually in progress or up next, so a resume phrase never starts
    /// something from scratch when a real resume point exists.
    func resolveResume(spoken: String) async -> [Ranked] {
        let needle = Self.normalize(spoken)
        var pool: [BaseItem] = []
        if let resume = try? await client.resumeItems(limit: 40) { pool += resume }
        if let next = try? await client.nextUp(limit: 40) { pool += next }

        var seen = Set<String>()
        var scored: [Ranked] = []
        for item in pool where seen.insert(item.id).inserted {
            guard !needle.isEmpty else {
                scored.append(Ranked(score: 0, match: .item(item)))
                continue
            }
            guard let score = Self.score(
                needle: needle,
                candidates: [item.displayTitle, item.seriesName, item.originalTitle])
            else { continue }
            scored.append(Ranked(score: score, match: .item(item)))
        }
        if needle.isEmpty { return scored }
        return scored.sorted { $0.score > $1.score }
    }

    /// "play something on Vlinder": the single best continuation — what the
    /// user was already watching, else the next episode waiting for them.
    func resolveSomething() async -> Match? {
        if let resume = try? await client.resumeItems(limit: 1), let first = resume.first {
            return .item(first)
        }
        if let next = try? await client.nextUp(limit: 1), let first = next.first {
            return .item(first)
        }
        return nil
    }

    private func itemsQuery(searchTerm: String) -> JellyfinClient.ItemsQuery {
        var query = JellyfinClient.ItemsQuery()
        query.searchTerm = searchTerm
        query.recursive = true
        query.limit = 30
        query.sortBy = "SortName"
        // Series resolve to the series; the resume path picks the episode.
        query.includeItemTypes = ["Movie", "Series", "Episode"]
        return query
    }

    // MARK: - Matching

    /// Punctuation, articles, and case are all things Siri transcribes
    /// inconsistently; strip them before comparing.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        var words = String(stripped).split(separator: " ").map(String.init)
        if words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// 3 = exact, 2 = the phrase names the start of the title, 1 = the phrase
    /// contains the whole title (or vice versa), nil = no match. Highest wins.
    ///
    /// Matching runs on whole words, never raw substrings. A channel numbered
    /// "8" is a substring of half the nonsense a microphone can produce, and a
    /// live test against the real server duly resolved gibberish to a channel
    /// until this was word-bounded.
    static func score(needle: String, candidates: [String?]) -> Int? {
        let needleWords = needle.split(separator: " ").map(String.init)
        guard !needleWords.isEmpty else { return nil }
        var best: Int?
        for candidate in candidates.compactMap({ $0 }) {
            let hayWords = normalize(candidate).split(separator: " ").map(String.init)
            guard !hayWords.isEmpty else { continue }
            let value: Int?
            if hayWords == needleWords {
                value = 3
            } else if hayWords.starts(with: needleWords) || needleWords.starts(with: hayWords) {
                value = 2
            } else if contains(hayWords, needleWords) || contains(needleWords, hayWords) {
                value = 1
            } else {
                value = nil
            }
            if let value, value > (best ?? 0) { best = value }
        }
        return best
    }

    /// Whole-word subsequence: does `haystack` contain `needle`'s words in order
    /// and adjacent?
    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
