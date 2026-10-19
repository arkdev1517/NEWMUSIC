import Combine
import Foundation

/// Typed, persisted application settings — the iOS counterpart of Android's
/// `data/settings/AppSettings.kt`. Only settings that have a real behaviour on
/// iOS live here; Android-only audio-pipeline knobs (USB DAC routing, PCM
/// output modes, DSD, refresh-rate forcing) have no equivalent API surface on
/// iOS and are documented as platform differences instead of being stored as
/// inert toggles. Defaults below match the Android defaults key-for-key where
/// the setting exists on both platforms.
@MainActor
final class AppSettings: ObservableObject {
    // MARK: Playback

    /// Android `autoplay` (default true): keep playing related songs when the
    /// queue runs out, seeded from the last track.
    @Published var autoplay: Bool { didSet { defaults.set(autoplay, forKey: Keys.autoplay) } }
    /// Android `playbackSpeed` (default 1.0, offered 0.5×–2.0×).
    @Published var playbackSpeed: Double { didSet { defaults.set(playbackSpeed, forKey: Keys.playbackSpeed) } }
    /// Android `crossfadeSeconds` (default 0, offered 0–12). On iOS this drives
    /// a volume fade at track boundaries; Android's dual-decoder sample-exact
    /// crossfade has no AVPlayer equivalent.
    @Published var crossfadeSeconds: Int { didSet { defaults.set(crossfadeSeconds, forKey: Keys.crossfadeSeconds) } }
    /// Android `shuffleEnabled` / `repeatMode`, persisted across launches.
    @Published var shuffleEnabled: Bool { didSet { defaults.set(shuffleEnabled, forKey: Keys.shuffleEnabled) } }
    @Published var repeatMode: RepeatMode { didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) } }
    /// Android `showNerdStats`: codec / bitrate / sample-rate line in the player.
    @Published var showNerdStats: Bool { didSet { defaults.set(showNerdStats, forKey: Keys.showNerdStats) } }

    // MARK: Audio quality (Android per-network ceilings)

    @Published var audioQualityWiFi: AudioQuality { didSet { defaults.set(audioQualityWiFi.rawValue, forKey: Keys.qualityWiFi) } }
    @Published var audioQualityCellular: AudioQuality { didSet { defaults.set(audioQualityCellular.rawValue, forKey: Keys.qualityCellular) } }

    // MARK: Downloads

    @Published var downloadQuality: AudioQuality { didSet { defaults.set(downloadQuality.rawValue, forKey: Keys.downloadQuality) } }
    /// Android `wifiOnlyDownloads` (default true).
    @Published var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: Keys.wifiOnlyDownloads) } }

    // MARK: Lyrics

    /// Android `syncedLyrics` (default true).
    @Published var syncedLyrics: Bool { didSet { defaults.set(syncedLyrics, forKey: Keys.syncedLyrics) } }
    /// Android `lyricsOffsetMs` (default 0): shifts every lyric timestamp.
    @Published var lyricsOffsetMs: Int { didSet { defaults.set(lyricsOffsetMs, forKey: Keys.lyricsOffsetMs) } }

    // MARK: Scrobbling

    @Published var lastfmEnabled: Bool { didSet { defaults.set(lastfmEnabled, forKey: Keys.lastfmEnabled) } }
    @Published var lastfmUsername: String { didSet { defaults.set(lastfmUsername, forKey: Keys.lastfmUsername) } }
    /// The two halves of the Last.fm integration can be used independently:
    /// publish "now playing" without recording scrobbles, or vice versa.
    /// Both default on once the master Last.fm toggle is enabled.
    @Published var lastfmScrobbleEnabled: Bool { didSet { defaults.set(lastfmScrobbleEnabled, forKey: Keys.lastfmScrobbleEnabled) } }
    @Published var lastfmNowPlaying: Bool { didSet { defaults.set(lastfmNowPlaying, forKey: Keys.lastfmNowPlaying) } }
    /// Scrobble only the lead artist (before ", ", " & ", …), as Android does.
    @Published var lastfmPrimaryArtistOnly: Bool { didSet { defaults.set(lastfmPrimaryArtistOnly, forKey: Keys.lastfmPrimaryArtistOnly) } }
    @Published var listenBrainzEnabled: Bool { didSet { defaults.set(listenBrainzEnabled, forKey: Keys.listenBrainzEnabled) } }
    @Published var listenBrainzPrimaryArtistOnly: Bool { didSet { defaults.set(listenBrainzPrimaryArtistOnly, forKey: Keys.listenBrainzPrimaryArtistOnly) } }
    /// Android `scrobbleMinDuration` (seconds, default 30) and the delay pair
    /// `scrobbleDelayPercent` (0.5) / `scrobbleDelaySeconds` (180): a track
    /// scrobbles after min(percent × duration, cap) of actual playback.
    @Published var scrobbleMinDuration: Int { didSet { defaults.set(scrobbleMinDuration, forKey: Keys.scrobbleMinDuration) } }
    @Published var scrobbleDelayPercent: Double { didSet { defaults.set(scrobbleDelayPercent, forKey: Keys.scrobbleDelayPercent) } }
    @Published var scrobbleDelaySeconds: Int { didSet { defaults.set(scrobbleDelaySeconds, forKey: Keys.scrobbleDelaySeconds) } }

    // MARK: Identity / onboarding

    /// Android `onboardingComplete`.
    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) } }
    /// The name from onboarding. Android shows it to friends in Listen
    /// Together, so it is written through to the party nickname key as well.
    @Published var displayName: String {
        didSet {
            defaults.set(displayName, forKey: Keys.displayName)
            defaults.set(displayName, forKey: "bitchord-listen-together-nickname-v1")
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let autoplay = "bitchord-autoplay-v1"
        static let playbackSpeed = "bitchord-playback-speed-v1"
        static let crossfadeSeconds = "bitchord-crossfade-seconds-v1"
        static let shuffleEnabled = "bitchord-shuffle-enabled-v1"
        static let repeatMode = "bitchord-repeat-mode-v1"
        static let showNerdStats = "bitchord-nerd-stats-v1"
        static let qualityWiFi = "bitchord-quality-wifi-v1"
        static let qualityCellular = "bitchord-quality-cellular-v1"
        static let downloadQuality = "bitchord-quality-download-v1"
        static let wifiOnlyDownloads = "bitchord-downloads-wifi-only-v1"
        static let syncedLyrics = "bitchord-synced-lyrics-v1"
        static let lyricsOffsetMs = "bitchord-lyrics-offset-ms-v1"
        static let lastfmEnabled = "bitchord-lastfm-enabled-v1"
        static let lastfmUsername = "bitchord-lastfm-username-v1"
        static let lastfmScrobbleEnabled = "bitchord-lastfm-scrobble-enabled-v1"
        static let lastfmNowPlaying = "bitchord-lastfm-now-playing-v1"
        static let lastfmPrimaryArtistOnly = "bitchord-lastfm-primary-artist-v1"
        static let listenBrainzEnabled = "bitchord-listenbrainz-enabled-v1"
        static let listenBrainzPrimaryArtistOnly = "bitchord-listenbrainz-primary-artist-v1"
        static let scrobbleMinDuration = "bitchord-scrobble-min-duration-v1"
        static let scrobbleDelayPercent = "bitchord-scrobble-delay-percent-v1"
        static let scrobbleDelaySeconds = "bitchord-scrobble-delay-seconds-v1"
        static let onboardingComplete = "bitchord-onboarding-complete-v1"
        static let displayName = "bitchord-display-name-v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoplay = defaults.object(forKey: Keys.autoplay) as? Bool ?? true
        let storedSpeed = defaults.double(forKey: Keys.playbackSpeed)
        playbackSpeed = storedSpeed > 0 ? min(max(storedSpeed, 0.5), 2.0) : 1.0
        crossfadeSeconds = min(max(defaults.integer(forKey: Keys.crossfadeSeconds), 0), 12)
        shuffleEnabled = defaults.bool(forKey: Keys.shuffleEnabled)
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: Keys.repeatMode)) ?? .off
        showNerdStats = defaults.bool(forKey: Keys.showNerdStats)
        audioQualityWiFi = AudioQuality(rawValue: defaults.string(forKey: Keys.qualityWiFi) ?? "") ?? .lossless
        audioQualityCellular = AudioQuality(rawValue: defaults.string(forKey: Keys.qualityCellular) ?? "") ?? .lossless
        downloadQuality = AudioQuality(rawValue: defaults.string(forKey: Keys.downloadQuality) ?? "") ?? .lossless
        wifiOnlyDownloads = defaults.object(forKey: Keys.wifiOnlyDownloads) as? Bool ?? true
        syncedLyrics = defaults.object(forKey: Keys.syncedLyrics) as? Bool ?? true
        lyricsOffsetMs = defaults.integer(forKey: Keys.lyricsOffsetMs)
        lastfmEnabled = defaults.bool(forKey: Keys.lastfmEnabled)
        lastfmUsername = defaults.string(forKey: Keys.lastfmUsername) ?? ""
        lastfmScrobbleEnabled = defaults.object(forKey: Keys.lastfmScrobbleEnabled) as? Bool ?? true
        lastfmNowPlaying = defaults.object(forKey: Keys.lastfmNowPlaying) as? Bool ?? true
        lastfmPrimaryArtistOnly = defaults.object(forKey: Keys.lastfmPrimaryArtistOnly) as? Bool ?? true
        listenBrainzEnabled = defaults.bool(forKey: Keys.listenBrainzEnabled)
        listenBrainzPrimaryArtistOnly = defaults.object(forKey: Keys.listenBrainzPrimaryArtistOnly) as? Bool ?? true
        let storedMin = defaults.integer(forKey: Keys.scrobbleMinDuration)
        scrobbleMinDuration = storedMin > 0 ? storedMin : 30
        let storedPercent = defaults.double(forKey: Keys.scrobbleDelayPercent)
        scrobbleDelayPercent = storedPercent > 0 ? min(storedPercent, 1) : 0.5
        let storedCap = defaults.integer(forKey: Keys.scrobbleDelaySeconds)
        scrobbleDelaySeconds = storedCap > 0 ? storedCap : 180
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        displayName = defaults.string(forKey: Keys.displayName)
            ?? defaults.string(forKey: "bitchord-listen-together-nickname-v1") ?? ""
    }

    /// The quality ceiling in force for the current connection, mirroring
    /// Android's `effectiveAudioQuality` (metered → cellular ceiling).
    func effectiveQuality(metered: Bool?) -> AudioQuality {
        metered == true ? audioQualityCellular : audioQualityWiFi
    }

    /// Android's `downloadsAllowedNow`: Wi-Fi-only downloads refuse to start
    /// on a metered connection.
    func downloadsAllowed(metered: Bool?) -> Bool {
        !(wifiOnlyDownloads && metered == true)
    }

    /// Snapshot/restore used by backup export-import. Values are written
    /// through the same keys the rest of the app reads.
    func exportValues() -> [String: String] {
        [
            "autoplay": autoplay ? "1" : "0",
            "playbackSpeed": String(playbackSpeed),
            "crossfadeSeconds": String(crossfadeSeconds),
            "shuffleEnabled": shuffleEnabled ? "1" : "0",
            "repeatMode": String(repeatMode.rawValue),
            "showNerdStats": showNerdStats ? "1" : "0",
            "audioQualityWiFi": audioQualityWiFi.rawValue,
            "audioQualityCellular": audioQualityCellular.rawValue,
            "downloadQuality": downloadQuality.rawValue,
            "wifiOnlyDownloads": wifiOnlyDownloads ? "1" : "0",
            "syncedLyrics": syncedLyrics ? "1" : "0",
            "lyricsOffsetMs": String(lyricsOffsetMs),
            "displayName": displayName
        ]
    }

    func importValues(_ values: [String: String]) {
        if let value = values["autoplay"] { autoplay = value == "1" }
        if let value = values["playbackSpeed"], let speed = Double(value) { playbackSpeed = min(max(speed, 0.5), 2.0) }
        if let value = values["crossfadeSeconds"], let seconds = Int(value) { crossfadeSeconds = min(max(seconds, 0), 12) }
        if let value = values["shuffleEnabled"] { shuffleEnabled = value == "1" }
        if let value = values["repeatMode"], let raw = Int(value), let mode = RepeatMode(rawValue: raw) { repeatMode = mode }
        if let value = values["showNerdStats"] { showNerdStats = value == "1" }
        if let value = values["audioQualityWiFi"], let quality = AudioQuality(rawValue: value) { audioQualityWiFi = quality }
        if let value = values["audioQualityCellular"], let quality = AudioQuality(rawValue: value) { audioQualityCellular = quality }
        if let value = values["downloadQuality"], let quality = AudioQuality(rawValue: value) { downloadQuality = quality }
        if let value = values["wifiOnlyDownloads"] { wifiOnlyDownloads = value == "1" }
        if let value = values["syncedLyrics"] { syncedLyrics = value == "1" }
        if let value = values["lyricsOffsetMs"], let offset = Int(value) { lyricsOffsetMs = offset }
        if let value = values["displayName"] { displayName = value }
    }
}

/// The quality ladder from Android's `PlayerEnums.kt` (`AudioQuality`).
/// `maxKbps` is the bitrate ceiling applied when picking a stream format;
/// on iOS the ladder can only choose among the AAC formats YouTube serves,
/// so Medium/High/Lossless all mean "best available" exactly as they do for
/// the YouTube source on Android (the lossless step there comes from addon
/// sources, which are a documented platform gap).
enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case lossless

    var id: String { rawValue }

    var maxKbps: Int {
        switch self {
        case .low: 64
        case .medium, .high, .lossless: Int.max
        }
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .lossless: "Lossless"
        }
    }

    var detail: String {
        switch self {
        case .low: "~64 kbps · smallest download"
        case .medium: "Best available · ~128 kbps AAC"
        case .high: "Best available from YouTube Music"
        case .lossless: "Best available · 256 kbps AAC where offered"
        }
    }

    var hourly: String {
        switch self {
        case .low: "29 MB/hr"
        case .medium: "58 MB/hr"
        case .high: "115 MB/hr"
        case .lossless: "115 MB/hr"
        }
    }
}

/// Mirrors the player's repeat cycle: off → all → one → off.
enum RepeatMode: Int, CaseIterable, Sendable {
    case off = 0
    case all = 1
    case one = 2

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var title: String {
        switch self {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }
}

/// The three-state rating Android sends to `like/like`, `like/dislike` and
/// `like/removelike` (`LikeStatus` in the shared code).
enum LikeStatus: String, Sendable {
    case like
    case dislike
    case indifferent
}
