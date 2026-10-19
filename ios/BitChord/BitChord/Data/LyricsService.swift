import AVFoundation
import Foundation

/// Lyrics lookup across the providers ported to iOS, in the order the
/// Android `LyricsRepository` prefers synced results:
///
/// 1. **LRCLIB** (`LrcLib.kt`) — key-less community database; exact `get` on
///    artist + title + duration, then a fuzzy `search` preferring the hit
///    closest in length. Line-synced, occasionally word-synced.
/// 2. **YouTube captions** (`YouTubeTranscriptLyrics`) — timed transcript of
///    the exact video.
/// 3. **YouTube Music's Lyrics tab** (`YouTubeMusicLyrics`) — plain text for
///    the exact video.
///
/// Local files use their embedded lyrics instead (`EmbeddedLyrics.kt`): an
/// ID3 USLT / iTunes ©lyr tag, parsed as synced LRC when it carries stamps.
/// Android's other providers (BetterLyrics, KuGou, Musixmatch, Genius, …)
/// are separate third-party contracts and are tracked as remaining gaps;
/// nothing is substituted for them.
actor LyricsService {
    private let service: any MusicService
    private let session: URLSession
    private var cache: [String: TrackLyrics] = [:]

    private static let lrclibBase = "https://lrclib.net/api"
    private static let agent = "BitChord (https://github.com/bitchord)"

    init(service: any MusicService, session: URLSession = .shared) {
        self.service = service
        self.session = session
    }

    func lyrics(for track: MusicTrack, localFileURL: URL?) async -> TrackLyrics? {
        if let cached = cache[track.id] { return cached }

        var result: TrackLyrics?
        if let localFileURL {
            result = await Self.embeddedLyrics(at: localFileURL)
        }

        if result == nil {
            result = await lrclibLyrics(
                title: track.title,
                artist: track.artist,
                durationSeconds: track.durationSeconds
            )
        }
        if result == nil, let videoID = track.videoID {
            if let lines = try? await service.transcriptLyrics(videoID: videoID), !lines.isEmpty {
                result = TrackLyrics(lines: lines, source: .transcript, isSynced: true)
            }
        }
        if result == nil, let videoID = track.videoID {
            if let lines = try? await service.youtubeLyrics(videoID: videoID), !lines.isEmpty {
                result = TrackLyrics(lines: lines, source: .youtubeMusic, isSynced: false)
            }
        }
        if let result { cache[track.id] = result }
        return result
    }

    // MARK: - LRCLIB (port of LrcLib.kt)

    private func lrclibLyrics(title: String, artist: String, durationSeconds: TimeInterval?) async -> TrackLyrics? {
        let cleanTitle = LyricsQueryCleaner.clean(title)
        let cleanArtist = LyricsQueryCleaner.clean(artist)
        let seconds = Int(durationSeconds ?? 0)

        var synced: String?
        if seconds > 0 {
            synced = await exactMatch(title: cleanTitle, artist: cleanArtist, seconds: seconds)
        }
        if synced == nil {
            synced = await bestSearchHit(title: cleanTitle, artist: cleanArtist, seconds: seconds)
        }
        guard let synced else { return nil }
        let lines = LRCParser.parse(synced)
        guard !lines.isEmpty else { return nil }
        return TrackLyrics(lines: lines, source: .lrclib, isSynced: true)
    }

    private func exactMatch(title: String, artist: String, seconds: Int) async -> String? {
        guard let data = await get("\(Self.lrclibBase)/get", query: [
            "track_name": title, "artist_name": artist, "duration": String(seconds)
        ]), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["syncedLyrics"] as? String
    }

    private func bestSearchHit(title: String, artist: String, seconds: Int) async -> String? {
        guard let data = await get("\(Self.lrclibBase)/search", query: [
            "track_name": title, "artist_name": artist
        ]), let hits = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        // Prefer whichever hit is closest in length to what is actually
        // playing — same song, different edit would drift otherwise.
        let usable = hits.filter { hit in
            ((hit["syncedLyrics"] as? String) ?? "").isEmpty == false
        }
        let best = usable.min { lhs, rhs in
            let leftDuration = (lhs["duration"] as? NSNumber)?.doubleValue ?? 0
            let rightDuration = (rhs["duration"] as? NSNumber)?.doubleValue ?? 0
            return abs(leftDuration - Double(seconds)) < abs(rightDuration - Double(seconds))
        }
        return best?["syncedLyrics"] as? String
    }

    private func get(_ base: String, query: [String: String]) async -> Data? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // MARK: - Embedded lyrics (port of EmbeddedLyrics.kt's role)

    static func embeddedLyrics(at url: URL) async -> TrackLyrics? {
        let asset = AVURLAsset(url: url)
        // ID3 unsynchronised-lyrics frame and the iTunes ©lyr atom, named by
        // their raw identifier spaces so either container answers.
        let identifiers = [
            AVMetadataIdentifier(rawValue: "id3/USLT"),
            AVMetadataIdentifier(rawValue: "itsk/©lyr")
        ]
        for identifier in identifiers.compactMap({ $0 }) {
            let formats: [AVMetadataFormat] = [.id3Metadata, .iTunesMetadata]
            for format in formats {
                let items = try? await asset.loadMetadata(for: format)
                let matching = AVMetadataItem.metadataItems(
                    from: items ?? [], filteredByIdentifier: identifier
                )
                guard let item = matching.first,
                      let text = try? await item.load(.stringValue),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if LRCParser.looksSynced(text) {
                    let lines = LRCParser.parse(text)
                    if !lines.isEmpty { return TrackLyrics(lines: lines, source: .embedded, isSynced: true) }
                }
                let lines = LRCParser.parsePlain(text)
                if !lines.isEmpty { return TrackLyrics(lines: lines, source: .embedded, isSynced: false) }
            }
        }
        return nil
    }
}
