import CryptoKit
import Foundation
import UIKit

/// URLSession-backed port of the repository's WEB_REMIX InnerTube calls.
/// The client version is refreshed from the live music.youtube.com shell; the
/// only fixed value is the same compatibility fallback used by Android.
actor InnerTubeService: MusicService {
    private let session: URLSession
    private let credentials: any CredentialStore
    private let musicAPI = URL(string: "https://music.youtube.com/youtubei/v1")!
    private let musicOrigin = "https://music.youtube.com"
    private let youtubeOrigin = "https://www.youtube.com"
    private let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private let fallbackClientVersion = "1.20250101.01.00"
    private var clientVersion: String?
    private var visitorData: String?
    private var sessionScope: SessionScope?

    private struct SessionScope {
        var cookie: String
        var dataSyncID: String?
        var pageID: String?
        var authUser: String
        var clientVersion: String?
    }

    init(session: URLSession? = nil, credentials: any CredentialStore = KeychainCredentialStore()) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 35
            self.session = URLSession(configuration: configuration)
        }
        self.credentials = credentials
    }

    func home() async throws -> MusicFeed {
        let response = try await musicRequest("browse", body: ["browseId": "FEmusic_home"])
        return MusicFeed(shelves: InnerTubeParser.parseHome(response), continuation: InnerTubeParser.continuationToken(response))
    }

    func homeRecentlyPlayed() async throws -> MusicShelf? {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else { return nil }
        let response = try await musicRequest("browse", body: ["browseId": "FEmusic_history"])
        let tracks = InnerTubeParser.parseHistoryTracks(response)
        guard !tracks.isEmpty else { return nil }
        let items = tracks.prefix(20).map { track in
            MusicItem(
                id: track.id,
                title: track.title,
                subtitle: track.artist,
                artworkURL: track.artworkURL,
                videoID: track.videoID,
                kind: .song
            )
        }
        return MusicShelf(id: "bitchord-recents", title: "Recents", items: items)
    }

    func homeSupplement(_ browseID: String) async throws -> [MusicShelf] {
        let response = try await musicRequest("browse", body: ["browseId": browseID])
        return InnerTubeParser.parseHome(response)
    }

    func moreHome(_ token: String) async throws -> MusicFeed {
        let response = try await musicRequest(
            "browse",
            query: ["ctoken": token, "continuation": token, "type": "next"],
            body: ["continuation": token]
        )
        return MusicFeed(shelves: InnerTubeParser.parseHomeContinuation(response), continuation: InnerTubeParser.continuationToken(response))
    }

    func explore() async throws -> [MusicCategorySection] {
        let response = try await musicRequest("browse", body: ["browseId": "FEmusic_moods_and_genres"])
        return InnerTubeParser.parseCategories(response)
    }

    func categoryShelves(browseID: String, params: String?) async throws -> [MusicShelf] {
        var body: [String: Any] = ["browseId": browseID]
        if let params { body["params"] = params }
        let response = try await musicRequest("browse", body: body)
        return InnerTubeParser.parseHome(response)
    }

    func searchPage(_ query: String, filter: SearchFilter) async throws -> MusicSearchPage {
        var body: [String: Any] = ["query": query]
        if let params = filter.innerTubeParams { body["params"] = params }
        let response = try await musicRequest("search", body: body, includeSession: true)
        return InnerTubeParser.parseSearch(response, filter: filter)
    }

    func moreSearch(_ token: String, filter: SearchFilter) async throws -> MusicSearchPage {
        let response = try await musicRequest(
            "search",
            query: ["ctoken": token, "continuation": token, "type": "next"],
            body: ["continuation": token]
        )
        return InnerTubeParser.parseSearch(response, filter: filter)
    }

    func searchSuggestions(_ query: String) async throws -> [String] {
        let response = try await musicRequest("music/get_search_suggestions", body: ["input": query])
        return InnerTubeParser.parseSuggestions(response)
    }

    func browsePage(_ route: BrowseRoute) async throws -> MusicBrowsePage {
        var body: [String: Any] = ["browseId": route.browseID]
        if let params = route.params { body["params"] = params }
        let response = try await musicRequest("browse", body: body)
        return InnerTubeParser.parseBrowsePage(response, route: route)
    }

    func moreBrowse(_ route: BrowseRoute, token: String) async throws -> MusicBrowsePage {
        let response = try await musicRequest(
            "browse",
            query: ["ctoken": token, "continuation": token, "type": "next"],
            body: ["continuation": token]
        )
        return InnerTubeParser.parseBrowsePage(response, route: route)
    }

    func library() async throws -> [MusicShelf] {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }

        // These browse IDs and shelf names are the same feeds read by
        // YtMusicRepository in the Android app. A failed optional shelf does
        // not hide the others; the caller still gets a real error if all fail.
        let feeds: [(String, String)] = [
            ("Playlists", "FEmusic_liked_playlists"),
            ("Albums", "FEmusic_liked_albums"),
            ("Artists", "FEmusic_library_corpus_track_artists"),
            ("Songs", "FEmusic_liked_videos")
        ]
        var shelves: [MusicShelf] = []
        var errors: [String] = []
        for (title, browseID) in feeds {
            do {
                let response = try await musicRequest("browse", body: ["browseId": browseID])
                var items = InnerTubeParser.parseLibraryItems(response)
                if title == "Songs" && items.isEmpty {
                    let route = BrowseRoute(browseID: browseID, title: title, kind: .playlist)
                    items = InnerTubeParser.parseBrowsePage(response, route: route).items
                }
                if !items.isEmpty { shelves.append(MusicShelf(id: browseID, title: title, items: items)) }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        do {
            let response = try await musicRequest("browse", body: ["browseId": "VLLM"])
            let route = BrowseRoute(browseID: "VLLM", title: "Liked Music", kind: .playlist)
            let page = InnerTubeParser.parseBrowsePage(response, route: route)
            if !page.tracks.isEmpty {
                let items = page.tracks.map { track in
                    MusicItem(id: track.id, title: track.title, subtitle: track.artist, artworkURL: track.artworkURL, videoID: track.videoID, kind: .song)
                }
                shelves.insert(MusicShelf(id: "VLLM", title: "Liked Music", items: items), at: 0)
            }
        } catch {
            errors.append(error.localizedDescription)
        }
        if shelves.isEmpty, let message = errors.first { throw MusicRequestError.service(message) }
        return shelves
    }

    func account() async throws -> MusicAccount {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }
        let response = try await musicRequest("account/account_menu", body: [:])
        guard let account = InnerTubeParser.parseAccount(response) else {
            throw MusicRequestError.service("YouTube Music did not expose an account profile for this session.")
        }
        return account
    }

    func setLiked(_ liked: Bool, videoID: String) async throws {
        try await rate(liked ? .like : .indifferent, videoID: videoID)
    }

    // MARK: - Stream resolution
    //
    // The same walk Android's `StreamResolver` performs, reduced to what iOS
    // can honestly do: try the player-client catalog from `PlayerClient.kt`
    // in order, take a direct URL when a client offers one, run the
    // JavaScriptCore decipher (the NewPipe-equivalent layer) when a client
    // only offers ciphered ones, probe the winner with a ranged request the
    // way Android probes, and remember per-video client refusals for ten
    // minutes (`EXCLUDE_MS`). The one Android layer with no iOS counterpart
    // here is PoToken (BotGuard) minting: clients that demand one fail this
    // walk and the next client is tried, exactly as a refused client is.
    // No URL is ever fabricated — every candidate came from a player
    // response for this video.

    private struct PlayerClientProfile {
        var clientName: String
        var clientNameHeader: String
        var clientVersion: String
        var userAgent: String
        var extraContext: [String: Any]
        var useMusicOrigin: Bool
        var needsSignatureTimestamp: Bool
        /// Whether the client runs in a browser, and so has to be fetched
        /// with an Origin and a Referer. The native app clients must not
        /// have them: a request dressed as a browser for a URL an app
        /// minted is as wrong as the other way round, and googlevideo
        /// refuses it (`PlayerClient.mediaHeaders` in the shared code says
        /// the same about the desktop and the phone).
        var isBrowserShaped: Bool
    }

    private var playerClients: [PlayerClientProfile] {
        let webRemixVersion = liveClientVersion
        let iosVersion = "21.29.1"
        let osVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return [
            PlayerClientProfile(
                clientName: "IOS", clientNameHeader: "5", clientVersion: iosVersion,
                userAgent: "com.google.ios.youtube/\(iosVersion) (iPhone16,2; U; CPU iOS \(osVersion) like Mac OS X;)",
                extraContext: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": osVersion.replacingOccurrences(of: "_", with: ".")],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: false
            ),
            PlayerClientProfile(
                clientName: "ANDROID_VR", clientNameHeader: "28", clientVersion: "1.65.10",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                extraContext: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L", "androidSdkVersion": 32],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: false
            ),
            PlayerClientProfile(
                clientName: "TVHTML5", clientNameHeader: "7", clientVersion: "7.20260707.07.00",
                userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
                extraContext: [:],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: true
            ),
            PlayerClientProfile(
                clientName: "IOS", clientNameHeader: "5", clientVersion: "21.26.4",
                userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                extraContext: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2"],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: false
            ),
            PlayerClientProfile(
                clientName: "WEB_REMIX", clientNameHeader: "67", clientVersion: webRemixVersion,
                userAgent: webUserAgent,
                extraContext: [:],
                useMusicOrigin: true, needsSignatureTimestamp: true, isBrowserShaped: true
            ),
            PlayerClientProfile(
                clientName: "WEB", clientNameHeader: "1", clientVersion: "2.20260708.00.00",
                userAgent: webUserAgent,
                extraContext: [:],
                useMusicOrigin: false, needsSignatureTimestamp: true, isBrowserShaped: true
            ),
            PlayerClientProfile(
                clientName: "ANDROID", clientNameHeader: "3", clientVersion: "21.26.364",
                userAgent: "com.google.android.youtube/21.26.364 (Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip",
                extraContext: ["osName": "Android", "osVersion": "15", "androidSdkVersion": 35],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: false
            ),
            PlayerClientProfile(
                clientName: "ANDROID_MUSIC", clientNameHeader: "21", clientVersion: "8.39.42",
                userAgent: "com.google.android.apps.youtube.music/8.39.42 (Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip",
                extraContext: ["osName": "Android", "osVersion": "15", "androidSdkVersion": 35],
                useMusicOrigin: false, needsSignatureTimestamp: false, isBrowserShaped: false
            )
        ]
    }

    private let decipher = SignatureDecipher()
    private var excludedClients: [String: [String: Date]] = [:]
    private var resolvedCache: [String: (streams: [ResolvedMusicStream], resolvedAt: Date)] = [:]
    private static let exclusionWindow: TimeInterval = 10 * 60
    private static let resolvedLifetime: TimeInterval = 5 * 60 * 60

    func resolveStream(for track: MusicTrack) async throws -> ResolvedMusicStream {
        try await resolveStream(for: track, quality: .lossless)
    }

    func resolveStream(for track: MusicTrack, quality: AudioQuality) async throws -> ResolvedMusicStream {
        guard let first = try await resolveStreams(for: track, quality: quality).first else {
            throw MusicRequestError.noPlayableStream
        }
        return first
    }

    /// Every stream that answered for this track, best first.
    ///
    /// The player takes the first and moves to the next when the one it was
    /// given is refused: a URL that cleared the probe can still be turned
    /// down by the CDN once the player asks it for the bytes it will
    /// actually read, so the whole list is the answer and not just its head.
    func resolveStreams(for track: MusicTrack, quality: AudioQuality) async throws -> [ResolvedMusicStream] {
        guard let videoID = track.videoID else { throw MusicRequestError.noPlayableStream }
        if let cached = resolvedCache[videoID],
           Date().timeIntervalSince(cached.resolvedAt) < Self.resolvedLifetime,
           (cached.streams.first?.bitrateKbps ?? Int.max) <= quality.maxKbps {
            return cached.streams
        }
        await ensureClientVersion()
        var lastRefusal: String?
        var sawCipherOnly = false
        for profile in playerClients {
            if isExcluded(client: profile.clientName + profile.clientVersion, videoID: videoID) { continue }
            do {
                let streams = try await resolveWithClient(profile, videoID: videoID, quality: quality)
                resolvedCache[videoID] = (streams, Date())
                return streams
            } catch let error as MusicRequestError {
                switch error {
                case .unsupportedFormat:
                    sawCipherOnly = true
                case .service(let message):
                    lastRefusal = message
                default:
                    break
                }
                exclude(client: profile.clientName + profile.clientVersion, videoID: videoID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                exclude(client: profile.clientName + profile.clientVersion, videoID: videoID)
            }
        }
        if let lastRefusal { throw MusicRequestError.service(lastRefusal) }
        if sawCipherOnly { throw MusicRequestError.unsupportedFormat }
        throw MusicRequestError.noPlayableStream
    }

    private func resolveWithClient(_ profile: PlayerClientProfile, videoID: String, quality: AudioQuality) async throws -> [ResolvedMusicStream] {
        let origin = profile.useMusicOrigin ? musicOrigin : youtubeOrigin
        var client: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": languageCode,
            "gl": regionCode
        ]
        for (key, value) in profile.extraContext { client[key] = value }
        if visitorData == nil { await fetchVisitorData() }
        if let visitorData { client["visitorData"] = visitorData }

        var body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if profile.needsSignatureTimestamp, let sts = await decipher.signatureTimestamp(videoID: videoID) {
            body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": sts]]
        }

        var headers = [
            "Origin": origin,
            "Referer": "\(origin)/",
            "X-YouTube-Client-Name": profile.clientNameHeader,
            "X-YouTube-Client-Version": profile.clientVersion,
            "User-Agent": profile.userAgent
        ]
        // The signed-in session rides along only on the music-web client,
        // where it is also what unlocks account-only (e.g. Premium 256k)
        // formats; app clients stay anonymous like they are on Android.
        if profile.useMusicOrigin, let cookie = credentials.string(for: SessionCredential.youtubeCookie) {
            await ensureSessionScope(for: cookie)
            headers["Cookie"] = cookie
            headers["X-Goog-AuthUser"] = sessionScope?.authUser ?? "0"
            if let pageID = sessionScope?.pageID { headers["X-Goog-PageId"] = pageID }
            if let sapisid = sapisid(in: cookie) {
                headers["Authorization"] = Self.sapisidAuthorization(sapisid, origin: musicOrigin)
            }
        }

        let response = try await postJSON(
            url: URL(string: "\(origin)/youtubei/v1/player?prettyPrint=false&hl=\(languageCode)")!,
            body: body,
            headers: headers
        )
        if let status = path(response, "playabilityStatus", "status") as? String, status != "OK" {
            let reason = (path(response, "playabilityStatus", "reason") as? String)
                ?? "YouTube cannot play this track right now (\(status))."
            throw MusicRequestError.service(reason)
        }
        let streaming = response["streamingData"] as? InnerTubeObject ?? [:]
        let formats = (streaming["adaptiveFormats"] as? [InnerTubeObject] ?? [])
            + (streaming["formats"] as? [InnerTubeObject] ?? [])
        let audioFormats = formats.filter { format in
            ((format["mimeType"] as? String) ?? "").lowercased().hasPrefix("audio/")
        }
        // AVFoundation plays AAC in an MP4 container; Opus/WebM formats are
        // real but unusable on iOS, so they never win here (Android's
        // ExoPlayer + FFmpeg extension is the platform difference).
        let playable = audioFormats.filter { format in
            let mime = ((format["mimeType"] as? String) ?? "").lowercased()
            return mime.contains("audio/mp4") || mime.contains("audio/aac")
        }
        guard !playable.isEmpty else {
            if audioFormats.contains(where: { $0["signatureCipher"] != nil || $0["cipher"] != nil }) {
                throw MusicRequestError.unsupportedFormat
            }
            throw MusicRequestError.noPlayableStream
        }

        func bitrateKbps(of format: InnerTubeObject) -> Int {
            let bits = (format["averageBitrate"] as? NSNumber)?.intValue
                ?? (format["bitrate"] as? NSNumber)?.intValue ?? 0
            return max(1, bits / 1000)
        }

        // Android's pick under a ceiling: the best rung at or under it first,
        // then the remaining rungs as fallbacks (never silently only the
        // biggest stream). When nothing fits under the ceiling, the lowest
        // rung above it leads.
        let ordered = playable.sorted { bitrateKbps(of: $0) < bitrateKbps(of: $1) }
        let underCeiling = ordered.filter { bitrateKbps(of: $0) <= quality.maxKbps }
        let primary = underCeiling.isEmpty ? Array(ordered.prefix(1)) : Array(underCeiling.reversed())
        let primaryItags = Set(primary.compactMap { ($0["itag"] as? NSNumber)?.intValue })
        let preferredOrder = primary + ordered.filter { format in
            guard let itag = (format["itag"] as? NSNumber)?.intValue else { return true }
            return !primaryItags.contains(itag)
        }

        // The headers the media fetch has to carry are the ones belonging to
        // the client that minted the URL, and every candidate names its own
        // — so they are worked out per candidate, not once for the client
        // that asked.
        var sawCipher = false
        var found: [ResolvedMusicStream] = []
        for format in preferredOrder {
            var candidateURL: URL?
            if let raw = format["url"] as? String, let url = URL(string: raw) {
                // A direct URL still carries an untransformed `n`; transform
                // is best-effort (a raw `n` serves, only slower).
                candidateURL = try? await decipher.transformNParameter(in: url, videoID: videoID)
                if candidateURL == nil { candidateURL = url }
            } else if let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String) {
                sawCipher = true
                candidateURL = try? await decipher.decipherURL(signatureCipher: cipher, videoID: videoID)
            }
            guard let url = candidateURL else { continue }
            let minting = clientMinting(url: url) ?? profile
            let headers = mediaHeaders(for: minting)
            guard await probe(url: url, headers: headers) else { continue }
            let mime = (format["mimeType"] as? String) ?? ""
            let codec = mime.components(separatedBy: "codecs=\"").last?
                .components(separatedBy: "\"").first ?? "AAC"
            found.append(ResolvedMusicStream(
                url: url,
                headers: headers,
                codec: codec,
                bitrateKbps: bitrateKbps(of: format),
                sampleRateHz: (format["audioSampleRate"] as? String).flatMap(Int.init)
                    ?? (format["audioSampleRate"] as? NSNumber)?.intValue,
                clientName: minting.clientName
            ))
            // A few answers is plenty: the player only wants a second one
            // for the case where the first is refused, and every probe is a
            // real read of the stream.
            if found.count >= Self.maxProbedStreams { break }
        }
        if found.isEmpty {
            if sawCipher && playable.allSatisfy({ $0["url"] == nil }) {
                throw MusicRequestError.unsupportedFormat
            }
            throw MusicRequestError.noPlayableStream
        }
        return found
    }

    /// The headers the media fetch for a URL has to carry.
    ///
    /// googlevideo compares the identity of the request that minted the URL
    /// with the one that fetches it, and refuses the fetch when they
    /// differ. The native app clients are therefore fetched with nothing
    /// but their agent — an Origin and a Referer would dress the request
    /// as a browser, which is as wrong for an app-minted URL as leaving
    /// them off a browser's. The browser-shaped clients keep both. This is
    /// `PlayerClient.mediaHeaders` in the shared code, which the phone and
    /// the desktop both fetch their streams with.
    private func mediaHeaders(for profile: PlayerClientProfile) -> [String: String] {
        var headers = ["User-Agent": profile.userAgent]
        if profile.isBrowserShaped {
            let origin = profile.useMusicOrigin ? musicOrigin : youtubeOrigin
            headers["Origin"] = origin
            headers["Referer"] = "\(origin)/"
        }
        return headers
    }

    /// The client a googlevideo URL says minted it, so the media fetch can
    /// be dressed as that client whatever produced the URL.
    private func clientMinting(url: URL) -> PlayerClientProfile? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let name = (query.first { $0.name == "c" }?.value ?? "").uppercased()
        guard !name.isEmpty else { return nil }
        let candidates = playerClients.filter { $0.clientName.uppercased() == name }
        guard !candidates.isEmpty else { return nil }
        if let version = query.first(where: { $0.name == "cver" })?.value,
           let exact = candidates.first(where: { $0.clientVersion == version }) {
            return exact
        }
        return candidates.first
    }

    /// Whether a URL really serves the bytes the player will ask it for.
    ///
    /// The range has to be as large as the real fetch's, not a token one:
    /// a URL minted for a session Google has reservations about serves
    /// small ranges to anybody — enough to pass a small probe — and then
    /// refuses the multi-megabyte ranges actual listening is made of, which
    /// is what the player runs into. The range starts past the megabyte
    /// when the file is that long, because some clients' URLs serve the
    /// first megabyte and refuse everything after it. And the answer has
    /// to be audio: a refusal dressed as a success — an error page — is a
    /// refusal. This is the shared resolver's probe, which the phone and
    /// the desktop both use before handing a URL to the player.
    private func probe(url: URL, headers: [String: String]) async -> Bool {
        let range = Self.probeRange(for: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200..<300).contains(http.statusCode) else { return false }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.hasPrefix("audio/") else { return false }
            // Headers can arrive long before a body that never does: the
            // bytes have to actually be there. Only the first stretch of
            // the answer is read — the range asked for is the big one, the
            // read is the small one.
            var read = 0
            for try await _ in bytes {
                read += 1
                if read >= Self.probeReadBytes { break }
            }
            return read >= min(Self.probeReadBytes, max(1, range.end - range.start + 1))
        } catch {
            return false
        }
    }

    /// The byte range the probe reads.
    ///
    /// It has to be as large as the range the real fetch asks for, and it
    /// starts past the megabyte when the file is that long: some clients'
    /// URLs serve the first megabyte and refuse everything after it, so a
    /// probe of the opening passes and playback dies a minute in.
    static func probeRange(for url: URL) -> (start: Int, end: Int) {
        let length = contentLength(of: url)
        let start = (length ?? 0) > authBoundaryBytes + probeReadBytes ? authBoundaryBytes : 0
        let end = min(start + probeRangeBytes, length ?? Int.max) - 1
        return (start, end)
    }

    /// The length the URL says its stream is, in bytes.
    static func contentLength(of url: URL) -> Int? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = query.first(where: { $0.name == "clen" })?.value,
              let length = Int(raw), length > 0 else { return nil }
        return length
    }

    /// Where googlevideo stops authorising some clients' URLs: they serve
    /// the first megabyte and refuse everything after it.
    private static let authBoundaryBytes = 1_048_576
    /// How much of the answer has to actually arrive for the URL to count.
    private static let probeReadBytes = 16_384
    /// The size of the range the probe asks for — as large as the range the
    /// real fetch asks for, which is the whole point of the probe.
    private static let probeRangeBytes = 1_048_576
    /// How many answers one client may keep: the player wants a second one
    /// for the case where the first is refused.
    private static let maxProbedStreams = 3

    private func isExcluded(client: String, videoID: String) -> Bool {
        guard let until = excludedClients[videoID]?[client] else { return false }
        if Date() > until {
            excludedClients[videoID]?[client] = nil
            return false
        }
        return true
    }

    private func exclude(client: String, videoID: String) {
        if excludedClients.count > 64 { excludedClients.removeAll() }
        excludedClients[videoID, default: [:]][client] = Date().addingTimeInterval(Self.exclusionWindow)
    }

    // MARK: - Radio, lyrics and history over InnerTube

    private func nextResponse(videoID: String) async throws -> InnerTubeObject {
        try await musicRequest("next", body: [
            "videoId": videoID,
            "playlistId": "RDAMVM\(videoID)",
            "isAudioOnly": true
        ])
    }

    func radio(videoID: String) async throws -> [MusicTrack] {
        let response = try await nextResponse(videoID: videoID)
        return InnerTubeParser.parseWatchQueue(response)
    }

    func youtubeLyrics(videoID: String) async throws -> [LyricLine]? {
        let next = try await nextResponse(videoID: videoID)
        guard let endpoint = InnerTubeParser.lyricsBrowseEndpoint(next) else { return nil }
        var body: [String: Any] = ["browseId": endpoint.browseID]
        if let params = endpoint.params { body["params"] = params }
        let page = try await musicRequest("browse", body: body)
        return InnerTubeParser.parseLyricsPage(page)
    }

    func transcriptLyrics(videoID: String) async throws -> [LyricLine]? {
        // get_transcript expects a tiny protobuf: field 1, length, video id.
        var bytes: [UInt8] = [10, UInt8(videoID.utf8.count)]
        bytes.append(contentsOf: videoID.utf8)
        let params = Data(bytes).base64EncodedString()
        let response = try await musicRequest("get_transcript", body: ["params": params])
        return InnerTubeParser.parseTranscript(response)
    }

    func historyTracks() async throws -> [MusicTrack] {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }
        let response = try await musicRequest("browse", body: ["browseId": "FEmusic_history"])
        return InnerTubeParser.parseHistoryTracks(response)
    }

    // MARK: - Account writes (verbatim ports of Innertube.kt)

    private func requireSession() throws {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }
    }

    func rate(_ status: LikeStatus, videoID: String) async throws {
        try requireSession()
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        // musicRequest inspects the body for an `error` object: Innertube
        // answers a refused write with HTTP 200 and the error in the body.
        _ = try await musicRequest(endpoint, body: ["target": ["videoId": videoID]])
    }

    func setSaved(_ saved: Bool, playlistID: String) async throws {
        try requireSession()
        let endpoint = saved ? "like/like" : "like/removelike"
        _ = try await musicRequest(endpoint, body: ["target": ["playlistId": playlistID]])
    }

    func setSubscribed(_ subscribed: Bool, channelID: String) async throws {
        try requireSession()
        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        _ = try await musicRequest(endpoint, body: ["channelIds": [channelID]])
    }

    func createPlaylist(title: String, description: String, videoIDs: [String]) async throws -> String {
        try requireSession()
        var body: [String: Any] = [
            "title": title,
            "description": description,
            "privacyStatus": "PRIVATE"
        ]
        if !videoIDs.isEmpty { body["videoIds"] = videoIDs }
        let response = try await musicRequest("playlist/create", body: body)
        if let playlistID = response["playlistId"] as? String, !playlistID.isEmpty { return playlistID }
        if let found = InnerTubeParser.findString(response, key: "playlistId") { return found }
        throw MusicRequestError.service("The playlist was created but YouTube Music returned no id for it.")
    }

    func deletePlaylist(_ playlistID: String) async throws {
        try requireSession()
        _ = try await musicRequest("playlist/delete", body: ["playlistId": playlistID.removingVLPrefix])
    }

    private func editPlaylist(_ playlistID: String, actions: [[String: Any]]) async throws -> InnerTubeObject {
        try requireSession()
        let response = try await musicRequest("browse/edit_playlist", body: [
            "playlistId": playlistID.removingVLPrefix,
            "actions": actions
        ])
        // The endpoint answers STATUS_SUCCEEDED rather than an HTTP error
        // when it refuses (a playlist the account merely saved, usually).
        if let status = response["status"] as? String, status != "STATUS_SUCCEEDED" {
            throw MusicRequestError.service("YouTube Music refused the edit (\(status)).")
        }
        return response
    }

    func addToPlaylist(_ playlistID: String, videoIDs: [String]) async throws -> [String: String] {
        let actions: [[String: Any]] = videoIDs.map { videoID in
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoID]
        }
        let response = try await editPlaylist(playlistID, actions: actions)
        var landed: [String: String] = [:]
        for result in (response["playlistEditResults"] as? [InnerTubeObject] ?? []) {
            guard let added = result["playlistEditVideoAddedResultData"] as? InnerTubeObject,
                  let videoID = added["videoId"] as? String,
                  let setVideoID = added["setVideoId"] as? String else { continue }
            landed[videoID] = setVideoID
        }
        return landed
    }

    func removeFromPlaylist(_ playlistID: String, entries: [PlaylistEntryRef]) async throws {
        let actions: [[String: Any]] = entries.map { entry in
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": entry.setVideoID, "removedVideoId": entry.videoID]
        }
        _ = try await editPlaylist(playlistID, actions: actions)
    }

    func accountPlaylists() async throws -> [MusicItem] {
        try requireSession()
        let response = try await musicRequest("browse", body: ["browseId": "FEmusic_liked_playlists"])
        return InnerTubeParser.parseLibraryItems(response).filter { $0.kind == .playlist || $0.browseID != nil }
    }

    func findArtistPageID(name: String) async throws -> String? {
        let wanted = name.normalizedArtistName
        guard !wanted.isEmpty else { return nil }
        let page = try await searchPage(name, filter: .artists)
        // A hit is accepted only when its own title is the name asked for —
        // the first search hit for a name is not necessarily that artist.
        return page.items.first { item in
            item.kind == .artist && item.title.normalizedArtistName == wanted
        }?.browseID
    }

    private var languageCode: String {
        Locale.current.languageCode ?? "en"
    }

    private var regionCode: String {
        Locale.current.regionCode ?? "US"
    }

    private func musicRequest(
        _ endpoint: String,
        query: [String: String] = [:],
        body payload: [String: Any],
        includeSession: Bool = true
    ) async throws -> InnerTubeObject {
        await ensureClientVersion()
        let cookie = includeSession ? credentials.string(for: SessionCredential.youtubeCookie) : nil
        if let cookie { await ensureSessionScope(for: cookie) }
        if visitorData == nil { await fetchVisitorData() }
        var contextClient: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": liveClientVersion,
            "hl": languageCode,
            "gl": regionCode
        ]
        if let visitorData { contextClient["visitorData"] = visitorData }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if cookie != nil, let dataSyncID = sessionScope?.dataSyncID { user["onBehalfOfUser"] = dataSyncID }
        var body: [String: Any] = [
            "context": [
                "client": contextClient,
                "user": user,
                "request": ["useSsl": true]
            ]
        ]
        for (key, value) in payload { body[key] = value }

        guard let endpointURL = URL(string: "\(musicAPI.absoluteString)/\(endpoint)"),
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw MusicRequestError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "hl", value: languageCode)
        ] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MusicRequestError.invalidResponse }
        var headers = [
            "Accept-Language": "\(languageCode),en;q=0.8",
            "Origin": musicOrigin,
            "X-Origin": musicOrigin,
            "Referer": "\(musicOrigin)/",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": liveClientVersion
        ]
        if let cookie {
            headers["Cookie"] = cookie
            headers["X-Goog-AuthUser"] = sessionScope?.authUser ?? "0"
            if let pageID = sessionScope?.pageID { headers["X-Goog-PageId"] = pageID }
            if let sapisid = sapisid(in: cookie) {
                headers["Authorization"] = Self.sapisidAuthorization(sapisid, origin: musicOrigin)
            }
        }
        let response = try await postJSON(url: url, body: body, headers: headers)
        if let visitor = path(response, "responseContext", "visitorData") as? String, !visitor.isEmpty {
            visitorData = visitor
        }
        if let error = response["error"] as? InnerTubeObject {
            throw MusicRequestError.service((error["message"] as? String) ?? "YouTube Music returned an error.")
        }
        return response
    }

    private var liveClientVersion: String {
        sessionScope?.clientVersion ?? clientVersion ?? fallbackClientVersion
    }

    private func ensureClientVersion() async {
        if clientVersion != nil { return }
        guard let url = URL(string: "\(musicOrigin)/") else {
            clientVersion = fallbackClientVersion
            return
        }
        var request = URLRequest(url: url)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(languageCode),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, _) = try await session.data(for: request)
            let html = String(decoding: data, as: UTF8.self)
            clientVersion = Self.capture("\"INNERTUBE_CLIENT_VERSION\"\\s*:\\s*\"([^\"]+)\"", from: html)
                ?? fallbackClientVersion
        } catch {
            clientVersion = fallbackClientVersion
        }
    }

    private func ensureSessionScope(for cookie: String) async {
        if sessionScope?.cookie == cookie { return }
        guard let url = URL(string: "\(musicOrigin)/") else { return }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(languageCode),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let sapisid = sapisid(in: cookie) {
            request.setValue(Self.sapisidAuthorization(sapisid, origin: musicOrigin), forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await session.data(for: request)
            let html = String(decoding: data, as: UTF8.self)
            let version = Self.capture("\"INNERTUBE_CLIENT_VERSION\"\\s*:\\s*\"([^\"]+)\"", from: html)
            clientVersion = version ?? clientVersion ?? fallbackClientVersion
            let loggedIn = Self.capture("\"LOGGED_IN\"\\s*:\\s*(true|false)", from: html) == "true"
            guard loggedIn else {
                sessionScope = SessionScope(cookie: cookie, dataSyncID: nil, pageID: nil, authUser: "0", clientVersion: version)
                return
            }
            let pageID = Self.capture("\"DELEGATED_SESSION_ID\"\\s*:\\s*\"([^\"]+)\"", from: html)
            let rawSync = Self.capture("\"DATASYNC_ID\"\\s*:\\s*\"([^\"]+)\"", from: html)
            let dataSync = Self.normalizeDataSyncID(rawSync)
            let authUser = Self.capture("\"SESSION_INDEX\"\\s*:\\s*\"?(\\d+)", from: html) ?? "0"
            if let visitor = Self.capture("\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"", from: html) { visitorData = visitor }
            sessionScope = SessionScope(cookie: cookie, dataSyncID: dataSync, pageID: pageID, authUser: authUser, clientVersion: version)
        } catch {
            // Same fail-open behaviour as Android: an unavailable shell does
            // not block anonymous browse/search or discard a valid cookie.
            sessionScope = SessionScope(cookie: cookie, dataSyncID: nil, pageID: nil, authUser: "0", clientVersion: clientVersion)
        }
    }

    private func fetchVisitorData() async {
        guard let url = URL(string: "\(youtubeOrigin)/sw.js_data") else { return }
        var request = URLRequest(url: url)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            let response = String(decoding: data, as: UTF8.self)
            visitorData = Self.capture("Cg[A-Za-z0-9_%-]{40,}", from: response)
        } catch {
            // InnerTube may still answer using the response's own visitor data.
        }
    }

    private func postJSON(url: URL, body: [String: Any], headers: [String: String]) async throws -> InnerTubeObject {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw MusicRequestError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var delay: UInt64 = 400_000_000
        for attempt in 0..<3 {
            do {
                let (responseData, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw MusicRequestError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw MusicRequestError.httpStatus(http.statusCode) }
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? InnerTubeObject else {
                    throw MusicRequestError.invalidResponse
                }
                return json
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MusicRequestError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                guard attempt < 2 else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw MusicRequestError.invalidResponse
    }

    private func sapisid(in cookieHeader: String) -> String? {
        let acceptable = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
        let cookies = cookieHeader.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces))
        }
        for name in acceptable {
            if let match = cookies.first(where: { $0.0 == name }), !match.1.isEmpty { return match.1 }
        }
        return nil
    }

    private static func sapisidAuthorization(_ sapisid: String, origin: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let source = Data("\(timestamp) \(sapisid) \(origin)".utf8)
        let digest = Insecure.SHA1.hash(data: source).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    private static func normalizeDataSyncID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.contains("||") else { return raw }
        let delegated = raw.components(separatedBy: "||").dropFirst().joined(separator: "||")
        return delegated.isEmpty ? raw.components(separatedBy: "||").first : delegated
    }

    private static func capture(_ pattern: String, from source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        let index = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: index), in: source) else { return nil }
        return String(source[range])
    }

    private func path(_ root: Any?, _ keys: String...) -> Any? {
        var cursor = root
        for key in keys {
            guard let dictionary = cursor as? InnerTubeObject else { return nil }
            cursor = dictionary[key]
        }
        return cursor
    }
}

extension String {
    /// The raw playlist id: `VL` is only the browse prefix, and the
    /// create/delete/edit endpoints refuse it.
    var removingVLPrefix: String {
        hasPrefix("VL") ? String(dropFirst(2)) : self
    }

    /// Case- and diacritic-insensitive name folding for the exact-artist
    /// match (Android's `normalizedArtistName`).
    var normalizedArtistName: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
