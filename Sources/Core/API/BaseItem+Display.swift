import Foundation

// Display helpers shared by rows, grids, and detail screens.
extension BaseItem {
    var displayTitle: String { name ?? "Untitled" }

    /// "S1 E5" style label for episodes.
    var episodeLabel: String? {
        guard type == .episode else { return nil }
        var parts: [String] = []
        if let season = parentIndexNumber { parts.append("S\(season)") }
        if let episode = indexNumber {
            if let end = indexNumberEnd, end != episode {
                parts.append("E\(episode)-\(end)")
            } else {
                parts.append("E\(episode)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Secondary line under a poster: series context for episodes, year for the rest.
    var posterSubtitle: String? {
        switch type {
        case .episode:
            return [episodeLabel, seriesName].compactMap(\.self).joined(separator: " · ")
        case .season:
            return seriesName
        case .tvChannel, .liveTvChannel:
            return currentProgram?.value.name
        default:
            return productionYear.map(String.init)
        }
    }

    var yearLabel: String? {
        if type == .series {
            let start = productionYear.map(String.init)
            let end: String?
            if status == "Continuing" {
                end = "Present"
            } else if let endDate {
                end = String(Calendar.current.component(.year, from: endDate))
            } else {
                end = nil
            }
            if let start, let end, start != end { return "\(start)–\(end)" }
            return start
        }
        return productionYear.map(String.init)
    }

    var runtimeLabel: String? {
        guard let runTime, runTime > 0 else { return nil }
        let minutes = Int(runTime / 60)
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    /// 0...1 watched progress for the resume bar.
    var progressFraction: Double? {
        guard let percentage = userData?.playedPercentage, percentage > 0 else { return nil }
        return min(max(percentage / 100, 0), 1)
    }

    var resumeTicks: Int64? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    var isPlayable: Bool {
        switch type {
        case .movie, .episode, .video, .trailer, .tvChannel, .liveTvChannel, .audio:
            return true
        default:
            return false
        }
    }

    // Live TV helpers (channel number fallback matches Tuner: Number ?? ChannelNumber).
    var displayChannelNumber: String? { number ?? channelNumber }

    /// 0...1 progress of the currently airing program.
    var currentProgramProgress: Double? {
        guard let program = currentProgram?.value,
              let start = program.startDate, let end = program.endDate,
              end > start
        else { return nil }
        let fraction = Date().timeIntervalSince(start) / end.timeIntervalSince(start)
        return min(max(fraction, 0), 1)
    }
}

struct ImageRef {
    var itemId: String
    var tag: String
    var type: JellyfinClient.ImageType
}

extension BaseItem {
    /// Poster image (2:3-ish). Episodes and seasons prefer the series poster.
    var posterRef: ImageRef? {
        if type == .episode || type == .season {
            if let seriesId, let tag = seriesPrimaryImageTag {
                return ImageRef(itemId: seriesId, tag: tag, type: .primary)
            }
        }
        if let tag = imageTags?["Primary"] {
            return ImageRef(itemId: id, tag: tag, type: .primary)
        }
        if let parentId = parentPrimaryFallbackId, let tag = parentPrimaryFallbackTag {
            return ImageRef(itemId: parentId, tag: tag, type: .primary)
        }
        return nil
    }

    /// Wide thumb (16:9). Episodes use their own still frame.
    var thumbRef: ImageRef? {
        if type == .episode, let tag = imageTags?["Primary"] {
            return ImageRef(itemId: id, tag: tag, type: .primary)
        }
        if let tag = imageTags?["Thumb"] {
            return ImageRef(itemId: id, tag: tag, type: .thumb)
        }
        if let parentThumbItemId, let parentThumbImageTag {
            return ImageRef(itemId: parentThumbItemId, tag: parentThumbImageTag, type: .thumb)
        }
        if let tag = backdropImageTags?.first {
            return ImageRef(itemId: id, tag: tag, type: .backdrop)
        }
        if let parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return ImageRef(itemId: parentBackdropItemId, tag: tag, type: .backdrop)
        }
        return posterRef
    }

    var backdropRef: ImageRef? {
        if let tag = backdropImageTags?.first {
            return ImageRef(itemId: id, tag: tag, type: .backdrop)
        }
        if let parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return ImageRef(itemId: parentBackdropItemId, tag: tag, type: .backdrop)
        }
        if let tag = imageTags?["Primary"] {
            return ImageRef(itemId: id, tag: tag, type: .primary)
        }
        return nil
    }

    var logoRef: ImageRef? {
        if let tag = imageTags?["Logo"] {
            return ImageRef(itemId: id, tag: tag, type: .logo)
        }
        if let parentLogoItemId, let parentLogoImageTag {
            return ImageRef(itemId: parentLogoItemId, tag: parentLogoImageTag, type: .logo)
        }
        return nil
    }

    private var parentPrimaryFallbackId: String? { seriesId ?? parentId }
    private var parentPrimaryFallbackTag: String? { seriesPrimaryImageTag }
}

extension JellyfinClient {
    func imageURL(_ ref: ImageRef?, maxWidth: Int? = nil, maxHeight: Int? = nil) -> URL? {
        guard let ref else { return nil }
        return imageURL(itemId: ref.itemId, type: ref.type, tag: ref.tag, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}
