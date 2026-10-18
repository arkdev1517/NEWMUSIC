import Foundation

typealias InnerTubeObject = [String: Any]

/// A deliberately small, defensive port of the renderer parsing used by
/// `shared/.../InnertubeParser.kt`. YouTube's renderer tree is not a stable
/// public schema, so unknown nodes are ignored rather than treated as valid
/// content.
enum InnerTubeParser {
    static func parseHome(_ root: InnerTubeObject) -> [MusicShelf] {
        let tabs = path(root, "contents", "singleColumnBrowseResultsRenderer", "tabs") as? [Any]
        let sections = tabs?.first.flatMap {
            path($0, "tabRenderer", "content", "sectionListRenderer", "contents") as? [Any]
        } ?? []

        let parsed = sections.compactMap { section -> MusicShelf? in
            if let carousel = object(path(section, "musicCarouselShelfRenderer")) {
                return parseCarousel(carousel)
            }
            if let shelf = object(path(section, "musicShelfRenderer")) {
                return parsePlainShelf(shelf)
            }
            return nil
        }
        if !parsed.isEmpty { return parsed }
        return parseHomeContinuation(root)
    }

    static func parseHomeContinuation(_ root: Any) -> [MusicShelf] {
        var shelves: [MusicShelf] = []
        for renderer in collect(root, key: "musicCarouselShelfRenderer") {
            if let shelf = parseCarousel(renderer) { shelves.append(shelf) }
        }
        for renderer in collect(root, key: "musicShelfRenderer") {
            if let shelf = parsePlainShelf(renderer) { shelves.append(shelf) }
        }
        return shelves
    }

    static func parseSearch(_ root: InnerTubeObject, filter: SearchFilter) -> MusicSearchPage {
        var items: [MusicItem] = []
        var seen = Set<String>()
        let includeVideos = filter == .videos

        if !includeVideos {
            for card in collect(root, key: "musicCardShelfRenderer") {
                if let item = parseCardShelf(card), seen.insert(item.id).inserted {
                    items.append(item)
                }
            }
        }

        for renderer in collect(root, key: "musicResponsiveListItemRenderer") {
            // Album/artist/playlist rows may also carry an overlay video id;
            // classify their browse endpoint before attempting a track parse.
            if let item = parseBrowseItem(renderer) {
                if seen.insert(item.id).inserted { items.append(item) }
            } else if let track = parseTrack(renderer) {
                guard track.isVideo == includeVideos else { continue }
                let item = MusicItem(
                    id: track.id,
                    title: track.title,
                    subtitle: track.artist,
                    artworkURL: track.artworkURL,
                    videoID: track.videoID,
                    kind: .song,
                    isVideo: track.isVideo
                )
                if seen.insert(item.id).inserted { items.append(item) }
            }
        }
        return MusicSearchPage(items: items, continuation: continuationToken(root))
    }

    static func parseSuggestions(_ root: InnerTubeObject) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for renderer in collect(root, key: "searchSuggestionRenderer") {
            let endpointQuery = text(path(renderer, "navigationEndpoint", "searchEndpoint", "query"))
            let value = endpointQuery.isEmpty ? text(renderer["suggestion"]) : endpointQuery
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result
    }

    static func parseCategories(_ root: InnerTubeObject) -> [MusicCategorySection] {
        let tabs = path(root, "contents", "singleColumnBrowseResultsRenderer", "tabs") as? [Any]
        let sections = tabs?.first.flatMap {
            path($0, "tabRenderer", "content", "sectionListRenderer", "contents") as? [Any]
        } ?? []
        var parsed: [MusicCategorySection] = []
        for section in sections {
            guard let grid = object(path(section, "gridRenderer")) else { continue }
            let header = text(path(grid, "header", "gridHeaderRenderer", "title"))
            guard !header.isEmpty, let entries = grid["items"] as? [Any] else { continue }
            let categories = entries.compactMap { entry -> MusicCategory? in
                guard let button = object(path(entry, "musicNavigationButtonRenderer")) else { return nil }
                let endpoint = object(path(button, "clickCommand", "browseEndpoint"))
                    ?? object(path(button, "navigationEndpoint", "browseEndpoint"))
                guard let endpoint,
                      let browseID = string(endpoint["browseId"]),
                      !browseID.isEmpty else { return nil }
                let title = text(button["buttonText"])
                guard !title.isEmpty else { return nil }
                let color = number(path(button, "solid", "leftStripeColor"))
                    .map { UInt32(truncatingIfNeeded: Int($0)) }
                return MusicCategory(
                    title: title,
                    browseID: browseID,
                    params: string(endpoint["params"]),
                    stripeColor: color,
                    artworkURL: nil
                )
            }
            if !categories.isEmpty { parsed.append(MusicCategorySection(title: header, categories: categories)) }
        }
        return parsed
    }

    static func parseBrowsePage(_ root: InnerTubeObject, route: BrowseRoute) -> MusicBrowsePage {
        let header = firstRenderer(root, keys: ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"])
        let title = header.map { text($0["title"]) }.flatMap { $0.isEmpty ? nil : $0 } ?? route.title
        let subtitleParts = [text(header?["straplineTextOne"]), text(header?["subtitle"])]
            .filter { !$0.isEmpty }
        let subtitle = subtitleParts.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }.joined(separator: " • ")
        let artwork = header.flatMap(thumbnailURL) ?? route.artworkURL

        let playlistShelf = collect(root, key: "musicPlaylistShelfRenderer").first
        let rowScope: Any = playlistShelf ?? root
        let tracks = collect(rowScope, key: "musicResponsiveListItemRenderer")
            .compactMap(parseTrack)
            .deduplicated(by: \.id)
        let continuation = playlistShelf.flatMap(continuationToken) ?? continuationToken(root)

        var items = tracks.map { track in
            MusicItem(
                id: track.id,
                title: track.title,
                subtitle: track.artist,
                artworkURL: track.artworkURL,
                videoID: track.videoID,
                kind: .song
            )
        }
        if tracks.isEmpty {
            items = collect(root, key: "musicTwoRowItemRenderer")
                .compactMap(parseTwoRowItem)
                .deduplicated(by: \.id)
        }
        return MusicBrowsePage(
            title: title,
            subtitle: subtitle.isEmpty ? route.subtitle : subtitle,
            artworkURL: artwork,
            items: items,
            tracks: tracks,
            continuation: continuation
        )
    }

    static func parseHistoryTracks(_ root: Any) -> [MusicTrack] {
        collect(root, key: "musicResponsiveListItemRenderer")
            .compactMap(parseTrack)
            .deduplicated(by: \.id)
    }

    static func parseAccount(_ root: InnerTubeObject) -> MusicAccount? {
        guard let header = collect(root, key: "activeAccountHeaderRenderer").first else { return nil }
        let name = text(header["accountName"])
        guard !name.isEmpty else { return nil }
        let rawEmail = text(header["email"])
        let email = rawEmail.isEmpty ? text(header["channelHandle"]) : rawEmail
        let artwork = thumbnailURL(header)
        return MusicAccount(name: name, email: email, artworkURL: artwork)
    }

    static func parseLibraryItems(_ root: InnerTubeObject) -> [MusicItem] {
        var items = collect(root, key: "musicTwoRowItemRenderer").compactMap(parseTwoRowItem)
        items.append(contentsOf: collect(root, key: "musicResponsiveListItemRenderer").compactMap(parseBrowseItem))
        return items.deduplicated(by: \.id)
    }

    static func continuationToken(_ root: Any) -> String? {
        for renderer in collect(root, key: "continuationItemRenderer") {
            let endpoint = object(renderer["continuationEndpoint"])
            if let token = string(path(endpoint, "continuationCommand", "token")), !token.isEmpty {
                return token
            }
            let commands = path(endpoint, "commandExecutorCommand", "commands") as? [Any] ?? []
            for command in commands {
                if let token = string(path(command, "continuationCommand", "token")), !token.isEmpty {
                    return token
                }
            }
        }
        for renderer in collect(root, key: "nextContinuationData") {
            if let token = string(renderer["continuation"]), !token.isEmpty { return token }
        }
        return nil
    }

    static func parseDuration(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { TimeInterval($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func parseCarousel(_ renderer: InnerTubeObject) -> MusicShelf? {
        let header = object(path(renderer, "header", "musicCarouselShelfBasicHeaderRenderer"))
        let title = text(header?["title"])
        if title.localizedCaseInsensitiveContains("video") { return nil }
        let entries = renderer["contents"] as? [Any] ?? []
        let items = entries.compactMap { entry -> MusicItem? in
            if let twoRow = object(path(entry, "musicTwoRowItemRenderer")) {
                return parseTwoRowItem(twoRow)
            }
            if let row = object(path(entry, "musicResponsiveListItemRenderer")), let track = parseTrack(row) {
                return track.isVideo ? nil : MusicItem(
                    id: track.id,
                    title: track.title,
                    subtitle: track.artist,
                    artworkURL: track.artworkURL,
                    videoID: track.videoID,
                    kind: .song
                )
            }
            if let row = object(path(entry, "musicResponsiveListItemRenderer")) {
                return parseBrowseItem(row)
            }
            return nil
        }
        guard !items.isEmpty else { return nil }
        return MusicShelf(
            title: title.isEmpty ? "For you" : title,
            subtitle: text(header?["strapline"]),
            items: items
        )
    }

    private static func parsePlainShelf(_ renderer: InnerTubeObject) -> MusicShelf? {
        let title = text(renderer["title"])
        if title.localizedCaseInsensitiveContains("video") { return nil }
        let rows = renderer["contents"] as? [Any] ?? []
        let items = rows.compactMap { entry -> MusicItem? in
            guard let row = object(path(entry, "musicResponsiveListItemRenderer")),
                  let track = parseTrack(row), !track.isVideo else { return nil }
            return MusicItem(
                id: track.id,
                title: track.title,
                subtitle: track.artist,
                artworkURL: track.artworkURL,
                videoID: track.videoID,
                kind: .song
            )
        }
        guard !items.isEmpty else { return nil }
        return MusicShelf(title: title.isEmpty ? "For you" : title, items: items)
    }

    private static func parseCardShelf(_ renderer: InnerTubeObject) -> MusicItem? {
        let endpoint = object(path(renderer, "onTap", "watchEndpoint"))
        guard let videoID = string(endpoint?["videoId"]), !videoID.isEmpty else {
            if let browse = object(path(renderer, "onTap", "browseEndpoint")) {
                return browseItem(endpoint: browse, title: text(renderer["title"]), subtitle: text(renderer["subtitle"]), artwork: thumbnailURL(renderer))
            }
            return nil
        }
        let title = text(renderer["title"])
        guard !title.isEmpty else { return nil }
        return MusicItem(
            id: "youtube:\(videoID)",
            title: title,
            subtitle: text(renderer["subtitle"]),
            artworkURL: thumbnailURL(renderer),
            videoID: videoID,
            kind: .song
        )
    }

    private static func parseBrowseItem(_ renderer: InnerTubeObject) -> MusicItem? {
        guard let endpoint = object(path(renderer, "navigationEndpoint", "browseEndpoint")) else { return nil }
        let columns = renderer["flexColumns"] as? [Any] ?? []
        let title = text(path(columns.first, "musicResponsiveListItemFlexColumnRenderer", "text"))
        guard !title.isEmpty else { return nil }
        let subtitle = text(path(columns.dropFirst().first, "musicResponsiveListItemFlexColumnRenderer", "text"))
        return browseItem(endpoint: endpoint, title: title, subtitle: subtitle, artwork: thumbnailURL(renderer))
    }

    private static func browseItem(endpoint: InnerTubeObject, title: String, subtitle: String, artwork: String?) -> MusicItem? {
        guard let browseID = string(endpoint["browseId"]), !browseID.isEmpty, !title.isEmpty else { return nil }
        let pageType = string(path(endpoint, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")) ?? ""
        let kind: BrowseKind
        if pageType.contains("ALBUM") { kind = .album }
        else if pageType.contains("ARTIST") { kind = .artist }
        else if pageType.contains("PLAYLIST") { kind = .playlist }
        else { kind = .other }
        return MusicItem(
            id: "browse:\(browseID)",
            title: title,
            subtitle: subtitle,
            artworkURL: artwork,
            browseID: browseID,
            kind: kind,
            params: string(endpoint["params"])
        )
    }

    private static func parseTwoRowItem(_ renderer: InnerTubeObject) -> MusicItem? {
        let title = text(renderer["title"])
        guard !title.isEmpty else { return nil }
        let subtitle = text(renderer["subtitle"])
        let artwork = thumbnailURL(renderer)
        if let endpoint = object(path(renderer, "navigationEndpoint", "browseEndpoint")) {
            return browseItem(endpoint: endpoint, title: title, subtitle: subtitle, artwork: artwork)
        }
        if let videoID = string(path(renderer, "navigationEndpoint", "watchEndpoint", "videoId")) {
            return MusicItem(id: "youtube:\(videoID)", title: title, subtitle: subtitle, artworkURL: artwork, videoID: videoID, kind: .song)
        }
        return nil
    }

    private static func parseTrack(_ renderer: InnerTubeObject) -> MusicTrack? {
        let videoID = string(path(renderer, "playlistItemData", "videoId"))
            ?? string(path(renderer, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"))
            ?? string(path(renderer, "navigationEndpoint", "watchEndpoint", "videoId"))
        guard let videoID, !videoID.isEmpty else { return nil }
        let columns = renderer["flexColumns"] as? [Any] ?? []
        let title = text(path(columns.first, "musicResponsiveListItemFlexColumnRenderer", "text"))
        guard !title.isEmpty else { return nil }
        let subtitle = text(path(columns.dropFirst().first, "musicResponsiveListItemFlexColumnRenderer", "text"))
        let parts = subtitle.components(separatedBy: " • ").filter { !$0.isEmpty }
        let duration = parts.last(where: isDuration)
            ?? ((renderer["fixedColumns"] as? [Any] ?? []).map {
                text(path($0, "musicResponsiveListItemFixedColumnRenderer", "text"))
            }.first(where: isDuration))
        let typeWords: Set<String> = ["song", "video", "album", "single", "ep", "artist", "playlist", "podcast", "episode"]
        let rowType = parts.first(where: { typeWords.contains($0.lowercased()) })?.lowercased()
        let artist = parts.first(where: { !isDuration($0) && !typeWords.contains($0.lowercased()) && !$0.localizedCaseInsensitiveContains(" plays") })
            ?? subtitle
        let art = thumbnailURL(renderer)
        let dimensions = finalThumbnail(renderer)
        let isWide = dimensions.map { width, height in
            width > 0 && height > 0 && !(0.85...1.15).contains(width / height)
        } ?? false
        return MusicTrack(
            videoID: videoID,
            title: title,
            artist: artist.isEmpty ? "Unknown artist" : artist,
            artworkURL: art,
            durationText: duration,
            albumName: nil,
            localFileName: nil,
            isVideo: rowType == "video" || isWide
        )
    }

    private static func isDuration(_ value: String) -> Bool {
        let pieces = value.split(separator: ":")
        return pieces.count >= 2 && pieces.allSatisfy { Int($0) != nil }
    }

    private static func firstRenderer(_ root: Any, keys: [String]) -> InnerTubeObject? {
        for key in keys {
            if let item = collect(root, key: key).first { return item }
        }
        return nil
    }

    private static func thumbnailURL(_ root: Any) -> String? {
        for container in collectContainers(root, key: "thumbnails") {
            let thumbnails = container["thumbnails"] as? [InnerTubeObject] ?? []
            if let url = thumbnails.last.flatMap({ string($0["url"]) }), !url.isEmpty { return url }
        }
        return nil
    }

    private static func finalThumbnail(_ root: Any) -> (Double, Double)? {
        for container in collectContainers(root, key: "thumbnails") {
            guard let thumbnails = container["thumbnails"] as? [InnerTubeObject], let last = thumbnails.last,
                  let width = number(last["width"]), let height = number(last["height"]) else { continue }
            return (width, height)
        }
        return nil
    }

    private static func collectContainers(_ node: Any, key: String) -> [InnerTubeObject] {
        var results: [InnerTubeObject] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 80 else { return }
            if let dict = value as? InnerTubeObject {
                if dict[key] != nil { results.append(dict) }
                for child in dict.values { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(node, depth: 0)
        return results
    }

    private static func collect(_ node: Any, key: String) -> [InnerTubeObject] {
        var results: [InnerTubeObject] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 80 else { return }
            if let dict = value as? InnerTubeObject {
                if let match = dict[key] as? InnerTubeObject { results.append(match) }
                for child in dict.values { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(node, depth: 0)
        return results
    }

    private static func object(_ value: Any?) -> InnerTubeObject? { value as? InnerTubeObject }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func path(_ root: Any?, _ keys: String...) -> Any? {
        var cursor = root
        for key in keys {
            guard let dict = cursor as? InnerTubeObject else { return nil }
            cursor = dict[key]
        }
        return cursor
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard let dict = value as? InnerTubeObject else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        if let direct = dict["text"] as? String { return direct }
        if let runs = dict["runs"] as? [Any] {
            return runs.compactMap { ($0 as? InnerTubeObject)?["text"] as? String }.joined()
        }
        return ""
    }
}


private extension Array {
    func deduplicated<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
