import Foundation

/// A renderer classification, kept separate from the URL-based browse id.
enum BrowseKind: String, Codable, Hashable, Sendable {
    case song
    case album
    case artist
    case playlist
    case other
}

/// The filters exposed by the Android Search tab, with the same InnerTube
/// params. `nil` is YouTube Music's mixed All page.
enum SearchSource: String, CaseIterable, Identifiable, Sendable {
    case youtubeMusic
    case localMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtubeMusic: "YouTube Music"
        case .localMusic: "On this iPhone"
        }
    }
}

enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case songs
    case videos
    case albums
    case artists
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .videos: "Videos"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var innerTubeParams: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoKEAkQChAFEAMQBA=="
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: "EgWKAQIoAWoKEAkQChAFEAMQBA=="
        }
    }
}

/// One YouTube Music card/row. A playable item has `videoID`; a collection
/// card has `browseID`; category navigation also preserves its opaque params.
struct MusicItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var artworkURL: String?
    var videoID: String?
    var browseID: String?
    var kind: BrowseKind
    var params: String?
    var isVideo: Bool

    init(
        id: String? = nil,
        title: String,
        subtitle: String = "",
        artworkURL: String? = nil,
        videoID: String? = nil,
        browseID: String? = nil,
        kind: BrowseKind = .other,
        params: String? = nil,
        isVideo: Bool = false
    ) {
        self.id = id ?? videoID ?? browseID ?? "\(kind.rawValue):\(title):\(subtitle)"
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.videoID = videoID
        self.browseID = browseID
        self.kind = kind
        self.params = params
        self.isVideo = isVideo
    }

    var isPlayable: Bool { videoID != nil }

    func track() -> MusicTrack? {
        guard let videoID else { return nil }
        return MusicTrack(
            videoID: videoID,
            title: title,
            artist: subtitle.isEmpty ? "Unknown artist" : subtitle,
            artworkURL: artworkURL,
            durationText: nil,
            albumName: nil,
            localFileName: nil,
            isVideo: isVideo
        )
    }

    func browseRoute() -> BrowseRoute? {
        guard let browseID else { return nil }
        return BrowseRoute(
            browseID: browseID,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            kind: kind,
            params: params
        )
    }
}

struct MusicShelf: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var items: [MusicItem]

    init(id: String? = nil, title: String, subtitle: String = "", items: [MusicItem]) {
        self.id = id ?? title.lowercased()
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

struct MusicCategory: Identifiable, Hashable, Sendable {
    var title: String
    var browseID: String
    var params: String?
    var stripeColor: UInt32?
    var artworkURL: String?

    var id: String { "\(browseID)|\(params ?? "")" }
}

struct MusicCategorySection: Identifiable, Hashable, Sendable {
    var title: String
    var categories: [MusicCategory]
    var id: String { title }
}

struct MusicFeed: Sendable {
    var shelves: [MusicShelf]
    var continuation: String?
}

struct MusicSearchPage: Sendable {
    var items: [MusicItem]
    var continuation: String?
}

struct BrowseRoute: Hashable, Identifiable, Sendable {
    var browseID: String
    var title: String
    var subtitle: String = ""
    var artworkURL: String? = nil
    var kind: BrowseKind = .other
    var params: String? = nil

    var id: String { "\(browseID)|\(params ?? "")" }
}

struct MusicBrowsePage: Sendable {
    var title: String
    var subtitle: String
    var artworkURL: String?
    var items: [MusicItem]
    var tracks: [MusicTrack]
    var continuation: String?
}

/// A track in a queue or the locally imported library. Remote YouTube identity
/// is kept as a video id; imported files are copied into app-owned storage and
/// addressed by their sandbox filename.
struct MusicTrack: Identifiable, Codable, Hashable, Sendable {
    var videoID: String?
    var title: String
    var artist: String
    var artworkURL: String?
    var durationText: String?
    var albumName: String?
    var localFileName: String?
    var isVideo: Bool = false

    var id: String {
        if let videoID, !videoID.isEmpty { return "youtube:\(videoID)" }
        return "local:\(localFileName ?? title)"
    }

    var durationSeconds: TimeInterval? {
        guard let durationText else { return nil }
        let pieces = durationText.split(separator: ":").compactMap { Double($0) }
        guard !pieces.isEmpty else { return nil }
        return pieces.reduce(0) { $0 * 60 + $1 }
    }

    var shareURL: URL? {
        guard let videoID else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components?.url
    }
}

struct MusicSearchHistory: Codable, Hashable, Identifiable, Sendable {
    var query: String
    var date: Date
    var id: String { query.lowercased() }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MusicRequestError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case service(String)
    case noPlayableStream
    case signInRequired
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The music service returned an unreadable response."
        case let .httpStatus(status):
            status == 401 || status == 403
                ? "YouTube Music refused this request. Check your sign-in or try again later."
                : "The music service returned HTTP \(status)."
        case let .service(message): message
        case .noPlayableStream:
            "YouTube did not provide a playable audio stream for this track."
        case .signInRequired:
            "Sign in to YouTube Music to use this account feature."
        case .unsupportedFormat:
            "This stream is not a format iOS can play directly."
        }
    }
}

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}
