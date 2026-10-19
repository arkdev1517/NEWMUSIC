import Combine
import CryptoKit
import Foundation

/// Scrobbling to Last.fm and ListenBrainz — ported from Android's
/// `data/scrobbling` (`ScrobbleManager`, `LastFM`, `ListenBrainzManager`,
/// `PrimaryArtist`).
///
/// Timing is Android's `ScrobbleManager`: a track scrobbles after
/// min(duration × delayPercent, delaySeconds) of *actual playing time*
/// (pausing freezes the countdown), and never when the track is shorter
/// than the minimum-duration setting. Now-playing is announced at track
/// start per each service's own switch.
///
/// Last.fm needs the user's own API keypair (Android reads an optional
/// build-time keypair and lets the user replace it in settings; there is no
/// build config here, so the settings fields are the source). The auth flow
/// is the standard token dance: `auth.getToken` → user approves in the
/// browser → `auth.getSession`. Secrets live in the Keychain.
@MainActor
final class ScrobbleManager: ObservableObject {
    @Published private(set) var isLastfmConnected = false
    @Published private(set) var hasListenBrainzToken = false
    @Published private(set) var hasLastfmKeypair = false

    private let settings: AppSettings
    private let credentials: any CredentialStore
    private let session: URLSession

    private var pendingLastfmToken: String?

    // In-flight scrobble timing.
    private var currentTrack: MusicTrack?
    private var currentDuration: TimeInterval = 0
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var lastTickAt: Date?
    private var scrobbled = false

    private static let lastfmEndpoint = "https://ws.audioscrobbler.com/2.0/"
    private static let listenBrainzSubmit = "https://api.listenbrainz.org/1/submit-listens"
    private static let userAgent = "BitChord (https://github.com/kushagrasinghx/BitChord)"

    init(settings: AppSettings, credentials: any CredentialStore, session: URLSession = .shared) {
        self.settings = settings
        self.credentials = credentials
        self.session = session
        refreshConnectionState()
    }

    private func refreshConnectionState() {
        isLastfmConnected = !(credentials.string(for: SessionCredential.lastfmSessionKey) ?? "").isEmpty
        hasLastfmKeypair = !(credentials.string(for: SessionCredential.lastfmAPIKey) ?? "").isEmpty
            && !(credentials.string(for: SessionCredential.lastfmSecret) ?? "").isEmpty
        hasListenBrainzToken = !(credentials.string(for: SessionCredential.listenBrainzToken) ?? "").isEmpty
    }

    // MARK: - Playback lifecycle

    func trackStarted(_ track: MusicTrack, duration: TimeInterval) {
        currentTrack = track
        currentDuration = duration > 0 ? duration : (track.durationSeconds ?? 0)
        startedAt = Date()
        accumulated = 0
        lastTickAt = nil
        scrobbled = false

        if settings.listenBrainzEnabled, hasListenBrainzToken {
            Task { await submitListenBrainz(track, type: "playing_now") }
        }
        if settings.lastfmEnabled, settings.lastfmNowPlaying, isLastfmConnected {
            Task { await submitLastfmNowPlaying(track) }
        }
    }

    func tick(isPlaying: Bool) {
        let now = Date()
        defer { lastTickAt = isPlaying ? now : nil }
        guard isPlaying, let last = lastTickAt, let track = currentTrack, !scrobbled else { return }
        let delta = now.timeIntervalSince(last)
        if delta > 0, delta < 5 { accumulated += delta }
        if Self.shouldScrobble(
            played: accumulated,
            duration: currentDuration,
            percent: settings.scrobbleDelayPercent,
            capSeconds: TimeInterval(settings.scrobbleDelaySeconds),
            minDuration: TimeInterval(settings.scrobbleMinDuration)
        ) {
            scrobbled = true
            let started = startedAt ?? now
            if settings.listenBrainzEnabled, hasListenBrainzToken {
                Task { await submitListenBrainz(track, type: "single", listenedAt: started) }
            }
            if settings.lastfmEnabled, settings.lastfmScrobbleEnabled, isLastfmConnected {
                Task { await submitLastfmScrobble(track, startedAt: started) }
            }
        }
    }

    func stopped() {
        currentTrack = nil
        startedAt = nil
        accumulated = 0
        lastTickAt = nil
        scrobbled = false
    }

    /// Android's rule: `min(duration * percent, cap)` of playing time, and
    /// the track must clear the minimum duration at all.
    nonisolated static func shouldScrobble(
        played: TimeInterval,
        duration: TimeInterval,
        percent: Double,
        capSeconds: TimeInterval,
        minDuration: TimeInterval
    ) -> Bool {
        guard duration >= minDuration, duration > 0 else { return false }
        return played >= min(duration * percent, capSeconds)
    }

    /// `PrimaryArtist.kt`: first credited artist; original preserved when no
    /// separator is present so names such as "AC/DC" remain intact.
    nonisolated static func primaryArtist(_ artist: String) -> String {
        let separator = try! NSRegularExpression(pattern: #"\s*,\s*|\s+&\s+|\s+＆\s+"#)
        let range = NSRange(artist.startIndex..., in: artist)
        guard let match = separator.firstMatch(in: artist, range: range),
              let matchRange = Range(match.range, in: artist) else { return artist }
        let first = String(artist[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? artist : first
    }

    private func artist(for track: MusicTrack, primaryOnly: Bool) -> String {
        primaryOnly ? Self.primaryArtist(track.artist) : track.artist
    }

    // MARK: - ListenBrainz

    func setListenBrainzToken(_ token: String?) {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? credentials.set(cleaned?.isEmpty == false ? cleaned : nil, for: SessionCredential.listenBrainzToken)
        refreshConnectionState()
    }

    func validateListenBrainzToken(_ token: String) async -> Bool {
        guard let url = URL(string: "https://api.listenbrainz.org/1/validate-token") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (object["valid"] as? Bool) ?? false
    }

    private func submitListenBrainz(_ track: MusicTrack, type: String, listenedAt: Date? = nil) async {
        guard let token = credentials.string(for: SessionCredential.listenBrainzToken), !token.isEmpty,
              let url = URL(string: Self.listenBrainzSubmit) else { return }
        var metadata: [String: Any] = [
            "artist_name": artist(for: track, primaryOnly: settings.listenBrainzPrimaryArtistOnly),
            "track_name": track.title,
            "additional_info": [
                "media_player": "BitChord",
                "submission_client": "BitChord iOS",
                "duration_ms": Int(((currentDuration > 0 ? currentDuration : (track.durationSeconds ?? 0)) * 1000).rounded())
            ]
        ]
        if let album = track.albumName, !album.isEmpty { metadata["release_name"] = album }
        var payload: [String: Any] = ["track_metadata": metadata]
        if type == "single" {
            payload["listened_at"] = Int((listenedAt ?? Date()).timeIntervalSince1970)
        }
        let body: [String: Any] = ["listen_type": type, "payload": [payload]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
    }

    // MARK: - Last.fm

    var lastfmAPIKey: String { credentials.string(for: SessionCredential.lastfmAPIKey) ?? "" }

    func setLastfmKeypair(apiKey: String, secret: String) {
        try? credentials.set(apiKey.trimmingCharacters(in: .whitespaces), for: SessionCredential.lastfmAPIKey)
        try? credentials.set(secret.trimmingCharacters(in: .whitespaces), for: SessionCredential.lastfmSecret)
        refreshConnectionState()
    }

    /// Step 1–2 of the token dance: fetch a token and hand back the URL the
    /// user approves in the browser.
    func lastfmAuthorizationURL() async throws -> URL {
        guard hasLastfmKeypair else {
            throw MusicRequestError.service("Enter your Last.fm API key and secret first.")
        }
        let response = try await lastfmCall(method: "auth.getToken", params: [:], signed: true)
        guard let token = response["token"] as? String, !token.isEmpty else {
            throw MusicRequestError.service("Last.fm did not return an auth token.")
        }
        pendingLastfmToken = token
        guard let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(lastfmAPIKey)&token=\(token)") else {
            throw MusicRequestError.invalidResponse
        }
        return url
    }

    /// Step 3: after the user approved in the browser, trade the token for
    /// a session key. Returns the Last.fm username.
    func completeLastfmAuthorization() async throws -> String {
        guard let token = pendingLastfmToken else {
            throw MusicRequestError.service("Start the Last.fm sign-in first.")
        }
        let response = try await lastfmCall(method: "auth.getSession", params: ["token": token], signed: true)
        guard let sessionObject = response["session"] as? [String: Any],
              let key = sessionObject["key"] as? String, !key.isEmpty else {
            throw MusicRequestError.service("Last.fm has not approved the sign-in yet. Approve access in the browser, then try again.")
        }
        let name = (sessionObject["name"] as? String) ?? ""
        try? credentials.set(key, for: SessionCredential.lastfmSessionKey)
        settings.lastfmUsername = name
        pendingLastfmToken = nil
        refreshConnectionState()
        return name
    }

    func signOutLastfm() {
        try? credentials.set(nil, for: SessionCredential.lastfmSessionKey)
        settings.lastfmUsername = ""
        pendingLastfmToken = nil
        refreshConnectionState()
    }

    private func submitLastfmNowPlaying(_ track: MusicTrack) async {
        guard let sessionKey = credentials.string(for: SessionCredential.lastfmSessionKey) else { return }
        var params = [
            "artist": artist(for: track, primaryOnly: settings.lastfmPrimaryArtistOnly),
            "track": track.title,
            "sk": sessionKey
        ]
        if let album = track.albumName, !album.isEmpty { params["album"] = album }
        if currentDuration > 0 { params["duration"] = String(Int(currentDuration.rounded())) }
        _ = try? await lastfmCall(method: "track.updateNowPlaying", params: params, signed: true)
    }

    private func submitLastfmScrobble(_ track: MusicTrack, startedAt: Date) async {
        guard let sessionKey = credentials.string(for: SessionCredential.lastfmSessionKey) else { return }
        var params = [
            "artist": artist(for: track, primaryOnly: settings.lastfmPrimaryArtistOnly),
            "track": track.title,
            "timestamp": String(Int(startedAt.timeIntervalSince1970)),
            "sk": sessionKey
        ]
        if let album = track.albumName, !album.isEmpty { params["album"] = album }
        if currentDuration > 0 { params["duration"] = String(Int(currentDuration.rounded())) }
        _ = try? await lastfmCall(method: "track.scrobble", params: params, signed: true)
    }

    /// One signed Last.fm POST. `api_sig` is md5 over the alphabetically
    /// sorted `key + value` pairs (minus `format`) with the secret appended
    /// — the scheme `LastFM.kt`'s `apiSig` implements.
    private func lastfmCall(method: String, params: [String: String], signed: Bool) async throws -> [String: Any] {
        let apiKey = lastfmAPIKey
        let secret = credentials.string(for: SessionCredential.lastfmSecret) ?? ""
        var all = params
        all["method"] = method
        all["api_key"] = apiKey
        if signed {
            all["api_sig"] = Self.signature(params: all, secret: secret)
        }
        all["format"] = "json"

        guard let url = URL(string: Self.lastfmEndpoint) else { throw MusicRequestError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.formEncode(all).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicRequestError.invalidResponse }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MusicRequestError.httpStatus(http.statusCode)
        }
        if let message = object["message"] as? String, object["error"] != nil {
            throw MusicRequestError.service(message)
        }
        return object
    }

    nonisolated static func signature(params: [String: String], secret: String) -> String {
        let joined = params.keys.sorted().map { "\($0)\(params[$0] ?? "")" }.joined() + secret
        return Insecure.MD5.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
