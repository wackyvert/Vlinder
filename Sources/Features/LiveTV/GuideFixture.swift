#if DEBUG
import Foundation

/// A pinned guide, for screenshots that are comparable across weeks.
///
/// Real channel ids from the live server (the three locals are the Tablo
/// tuner's copies — the IPTV duplicates were excluded so Tablo wins them) (so the real channel logos load, at
/// the real sizes) with synthetic programs laid out on the reference frame's
/// own clock — origin 09:00, now 09:15. Deliberately carries **no** program
/// images, because the server has none either: the Now Playing column has to
/// earn its living from synthesized slates, which is the production case.
///
/// Every cell state the guide can draw appears at least once:
/// normal, airing-now, badged, long-running, off-air ("Upcoming:"),
/// no-EPG-record ("No live content"), and a mid-lane hole.
enum GuideFixture {
    struct Channel {
        var id: String
        var number: String
        var name: String
        var imageTag: String
        var favorite: Bool
        var programs: [Program]
    }

    struct Program {
        /// Minutes from the window's origin.
        var start: Double
        var minutes: Double
        var title: String
        /// "New" marks a first run, which the payload models as the *absence*
        /// of a repeat. Channel-earned badges like 4K do not belong here.
        var badge: String?
    }

    static let channels: [Channel] = [
        Channel(
            id: "82055d2b0d4aca9c815e1faed57824e7", number: "411",
            name: "CBS", imageTag: "839bed8115dd18a46b4e248bad82c055",
            favorite: true,
            programs: [
                Program(start: 0, minutes: 60, title: "WCCO Mid-Morning", badge: nil),
                Program(start: 60, minutes: 60, title: "The Price Is Right", badge: "New"),
                Program(start: 120, minutes: 60, title: "The Young and the Restless", badge: nil),
                Program(start: 180, minutes: 120, title: "CBS News Minnesota", badge: nil),
            ]),
        Channel(
            id: "7f12f00af972659ebd797a7499c918fa", number: "991",
            name: "FOX", imageTag: "4f2c560765d8cbabd6f817921ecc9809",
            favorite: true,
            programs: [
                Program(start: 0, minutes: 60, title: "FOX 9 Good Day", badge: nil),
                Program(start: 60, minutes: 60, title: "The Jason Show", badge: "New"),
                Program(start: 120, minutes: 60, title: "The Jennifer Hudson Show", badge: nil),
                Program(start: 180, minutes: 120, title: "FOX 9 News at Noon", badge: nil),
            ]),
        Channel(
            id: "b8434a1046e5fe620d79b39a31c22568", number: "1111",
            name: "NBC", imageTag: "4119006e60d2c8d5dcc8608bbf1396e6",
            favorite: true,
            programs: [
                Program(start: 0, minutes: 60, title: "Today 3rd Hour", badge: nil),
                Program(start: 60, minutes: 60, title: "Today With Jenna & Sheinelle", badge: "New"),
                Program(start: 120, minutes: 60, title: "Live with Kelly & Mark", badge: "New"),
                Program(start: 180, minutes: 120, title: "KARE 11 News at Noon", badge: nil),
            ]),
        // Off-air: nothing airing, next thing is tonight. Renders "Upcoming:".
        Channel(
            id: "32c65311db2087aeb1bed7a93209f820", number: "25",
            name: "US: FOX SPORTS 4K", imageTag: "fb43049c0ca751abee074a79de336ab0",
            favorite: true,
            programs: [
                // The 4K badge on this row comes from the channel's name now,
                // not from the programme.
                Program(start: 660, minutes: 210, title: "Fresno State at USC", badge: nil),
            ]),
        // A long programme, then a second one — tests spanning and clipping.
        Channel(
            id: "fd6e9153810205d2438729256b42a3a6", number: "51",
            name: "US: ESPN HD", imageTag: "e9e7dc5c3008108f5e44d85216ca094d",
            favorite: true,
            programs: [
                Program(start: 0, minutes: 90, title: "First Take", badge: nil),
                Program(start: 90, minutes: 150, title: "Men's & Women's Second Round", badge: nil),
                Program(start: 240, minutes: 120, title: "SportsCenter", badge: nil),
            ]),
        // Mid-lane hole: gap between 10 and 60 minutes in.
        Channel(
            id: "60c9e29cc12d010b8de482c418458ef7", number: "52",
            name: "US: ESPN 2 HD", imageTag: "f189649c947534762f225ff5791633d7",
            favorite: false,
            programs: [
                Program(start: -50, minutes: 60, title: "Get Up", badge: nil),
                Program(start: 60, minutes: 60, title: "NFL Live", badge: "New"),
            ]),
        // No EPG record at all: "No live content right now".
        Channel(
            id: "061b3919add3b9926413197e02077a58", number: "76",
            name: "US: BIG TEN NETWORK HD", imageTag: "97864c82968b5c2737ac78767dd35412",
            favorite: false,
            programs: []),
    ]

    /// The reference frame's clock: today at 09:15, so the window opens at
    /// 09:00 and the now-marker lands 15 minutes in.
    static var pinnedNow: Date {
        Calendar.current.date(
            bySettingHour: 9, minute: 15, second: 0, of: Date()) ?? Date()
    }

    static var windowStart: Date { GuideClock.windowStart(for: pinnedNow) }

    // MARK: - Decoded payloads

    /// Channels as the API would return them, so the fixture goes through the
    /// same decode path as live data.
    static func decodedChannels() -> [BaseItem] {
        decode(channels.map { channel in
            [
                "Id": channel.id,
                "Name": channel.name,
                "Number": channel.number,
                "ChannelNumber": channel.number,
                "Type": "TvChannel",
                "ImageTags": ["Primary": channel.imageTag],
                "UserData": ["IsFavorite": channel.favorite],
            ] as [String: Any]
        })
    }

    static func decodedPrograms() -> [String: [BaseItem]] {
        var out: [String: [BaseItem]] = [:]
        for channel in channels where !channel.programs.isEmpty {
            out[channel.id] = decode(channel.programs.map { program in
                let start = windowStart.addingTimeInterval(program.start * 60)
                let end = start.addingTimeInterval(program.minutes * 60)
                var item: [String: Any] = [
                    "Id": "\(channel.id)-\(Int(program.start))",
                    "Name": program.title,
                    "Type": "Program",
                    "ChannelId": channel.id,
                    "ChannelName": channel.name,
                    "StartDate": stamp(start),
                    "EndDate": stamp(end),
                    "ImageTags": [String: String](),
                ]
                // "New" is the absence of a repeat marker, matching the real
                // XMLTV: it sets <previously-shown> on most rows and <new/> on
                // none. The fixture has to model that, or the badge passes here
                // and stays dark in production.
                item["IsRepeat"] = program.badge != "New"
                item["IsSeries"] = true
                return item
            })
        }
        return out
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func decode(_ objects: [[String: Any]]) -> [BaseItem] {
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let items = try? JellyfinJSON.decoder.decode([BaseItem].self, from: data)
        else {
            FileHandle.standardError.write(Data("guide-fixture: decode failed\n".utf8))
            return []
        }
        return items
    }
}
#endif
