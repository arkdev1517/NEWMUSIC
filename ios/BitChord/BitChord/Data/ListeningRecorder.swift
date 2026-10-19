import Combine
import Foundation

/// One finished (or abandoned) listen. `playedSeconds` is time the track
/// actually spent playing, not wall-clock since it started — a track paused
/// for an hour has not been listened to for an hour.
struct PlayEvent: Codable, Identifiable, Sendable {
    var id: String
    var videoID: String?
    var title: String
    var artist: String
    var albumName: String?
    var artworkURL: String?
    var startedAt: Date
    var playedSeconds: Double
    var countsAsPlay: Bool

    func asTrack() -> MusicTrack {
        MusicTrack(
            videoID: videoID,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            durationText: nil,
            albumName: albumName,
            localFileName: id.hasPrefix("local:") ? String(id.dropFirst("local:".count)) : nil
        )
    }
}

/// Listening history + statistics, the iOS counterpart of Android's
/// `ListeningRecorder` + `ListeningStats`.
///
/// Android samples playback each second and folds plays into monthly
/// buckets; this keeps the raw event log (capped, oldest pruned) and
/// aggregates on read, which answers the same questions — top tracks,
/// artists and albums, time listened, per month/year/all-time — with one
/// honest store the backup export can carry verbatim. The play-counting
/// rule is Android's exactly: a play counts once actual playing time
/// reaches min(half the track, 4 minutes), and never before 30 seconds.
@MainActor
final class ListeningRecorder: ObservableObject {
    @Published private(set) var events: [PlayEvent] = []

    private let directory: URL
    private let fileName = "listening-events.json"
    private static let maxEvents = 5_000

    // In-flight listen accumulation.
    private var currentTrack: MusicTrack?
    private var currentDuration: TimeInterval = 0
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var lastTickAt: Date?
    private var counted = false

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = support.appendingPathComponent("Listening", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Recording

    /// Playback moved to a (possibly the same) track. The previous listen is
    /// closed out first.
    func begin(_ track: MusicTrack, duration: TimeInterval) {
        finishCurrent()
        currentTrack = track
        currentDuration = duration > 0 ? duration : (track.durationSeconds ?? 0)
        startedAt = Date()
        accumulated = 0
        lastTickAt = nil
        counted = false
    }

    func updateDuration(_ duration: TimeInterval) {
        if duration > 0 { currentDuration = duration }
    }

    /// Called on playback position ticks while playing; pass `isPlaying`
    /// false on pause so paused time never accumulates.
    func tick(isPlaying: Bool) {
        let now = Date()
        defer { lastTickAt = isPlaying ? now : nil }
        guard isPlaying, let last = lastTickAt else { return }
        let delta = now.timeIntervalSince(last)
        // A tick after a long suspension must not credit the whole gap.
        if delta > 0, delta < 5 { accumulated += delta }
        if !counted, Self.countsAsPlay(played: accumulated, duration: currentDuration) {
            counted = true
        }
    }

    /// Playback stopped entirely (queue exhausted / stop).
    func stop() {
        finishCurrent()
        currentTrack = nil
    }

    nonisolated static func countsAsPlay(played: TimeInterval, duration: TimeInterval) -> Bool {
        let floorSeconds: TimeInterval = 30
        let ceilingSeconds: TimeInterval = 4 * 60
        let threshold = duration > 0
            ? max(min(duration / 2, ceilingSeconds), floorSeconds)
            : floorSeconds
        return played >= threshold
    }

    private func finishCurrent() {
        guard let track = currentTrack, let startedAt else { return }
        // Plays too short to mean anything are still history — a skip at
        // 0:20 reports the twenty seconds it did play — but a track that
        // never produced a second of audio leaves no trace.
        if accumulated >= 1 {
            let event = PlayEvent(
                id: track.id,
                videoID: track.videoID,
                title: track.title,
                artist: track.artist,
                albumName: track.albumName,
                artworkURL: track.artworkURL,
                startedAt: startedAt,
                playedSeconds: accumulated,
                countsAsPlay: counted || Self.countsAsPlay(played: accumulated, duration: currentDuration)
            )
            events.insert(event, at: 0)
            if events.count > Self.maxEvents { events = Array(events.prefix(Self.maxEvents)) }
            persist()
        }
        self.startedAt = nil
        accumulated = 0
        lastTickAt = nil
        counted = false
    }

    // MARK: - History (tracks most recently heard, de-duplicated)

    var recentTracks: [MusicTrack] {
        var seen = Set<String>()
        return events.compactMap { event in
            seen.insert(event.id).inserted ? event.asTrack() : nil
        }
    }

    func clearHistory() {
        events = []
        persist()
    }

    // MARK: - Statistics

    nonisolated struct RankedEntry: Identifiable, Sendable {
        var id: String
        var title: String
        var subtitle: String
        var artworkURL: String?
        var plays: Int
        var seconds: Double
        var track: MusicTrack?
    }

    nonisolated struct Summary: Sendable {
        var totalPlays: Int
        var totalSeconds: Double
        var topTracks: [RankedEntry]
        var topArtists: [RankedEntry]
        var topAlbums: [RankedEntry]
    }

    nonisolated enum Period: String, CaseIterable, Identifiable, Sendable {
        case month
        case year
        case allTime

        var id: String { rawValue }
        var title: String {
            switch self {
            case .month: "This month"
            case .year: "This year"
            case .allTime: "All time"
            }
        }

        func contains(_ date: Date, now: Date = Date()) -> Bool {
            let calendar = Calendar.current
            switch self {
            case .allTime: return true
            case .month:
                return calendar.isDate(date, equalTo: now, toGranularity: .month)
            case .year:
                return calendar.isDate(date, equalTo: now, toGranularity: .year)
            }
        }
    }

    func summary(period: Period) -> Summary {
        Self.summarize(events.filter { period.contains($0.startedAt) })
    }

    nonisolated static func summarize(_ events: [PlayEvent]) -> Summary {
        let plays = events.filter { $0.countsAsPlay }
        func rank<Key: Hashable>(
            by key: (PlayEvent) -> Key?,
            build: (PlayEvent, Int, Double) -> RankedEntry
        ) -> [RankedEntry] {
            var representative: [Key: PlayEvent] = [:]
            var counts: [Key: (plays: Int, seconds: Double)] = [:]
            for event in plays {
                guard let k = key(event) else { continue }
                if representative[k] == nil { representative[k] = event }
                counts[k, default: (0, 0)].plays += 1
                counts[k, default: (0, 0)].seconds += event.playedSeconds
            }
            return counts.compactMap { k, value in
                representative[k].map { build($0, value.plays, value.seconds) }
            }.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.seconds > $1.seconds }
        }

        return Summary(
            totalPlays: plays.count,
            totalSeconds: events.reduce(0) { $0 + $1.playedSeconds },
            topTracks: Array(rank(by: { $0.id }) { event, count, seconds in
                RankedEntry(id: event.id, title: event.title, subtitle: event.artist,
                            artworkURL: event.artworkURL, plays: count, seconds: seconds, track: event.asTrack())
            }.prefix(10)),
            topArtists: Array(rank(by: { $0.artist.lowercased() }) { event, count, seconds in
                RankedEntry(id: "artist:\(event.artist.lowercased())", title: event.artist, subtitle: "",
                            artworkURL: event.artworkURL, plays: count, seconds: seconds, track: nil)
            }.prefix(10)),
            topAlbums: Array(rank(by: { event in
                event.albumName.map { "\($0.lowercased())\u{1F}\(event.artist.lowercased())" }
            }) { event, count, seconds in
                RankedEntry(id: "album:\(event.albumName ?? "")", title: event.albumName ?? "",
                            subtitle: event.artist, artworkURL: event.artworkURL,
                            plays: count, seconds: seconds, track: nil)
            }.prefix(10))
        )
    }

    // MARK: - Backup

    func importEvents(_ imported: [PlayEvent]) {
        events = (imported + events).sorted { $0.startedAt > $1.startedAt }
        if events.count > Self.maxEvents { events = Array(events.prefix(Self.maxEvents)) }
        persist()
    }

    // MARK: - Persistence

    private var fileURL: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PlayEvent].self, from: data) else { return }
        events = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
