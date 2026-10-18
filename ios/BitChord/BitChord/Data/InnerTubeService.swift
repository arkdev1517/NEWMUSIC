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
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }
        let endpoint = liked ? "like/like" : "like/removelike"
        let response = try await musicRequest(endpoint, body: ["target": ["videoId": videoID]])
        if let error = response["error"] as? InnerTubeObject {
            let message = (error["message"] as? String) ?? "YouTube Music refused the change."
            throw MusicRequestError.service(message)
        }
    }

    /// Best-effort native playback using the repository's iOS InnerTube client.
    /// Android also has InnerTubeX + NewPipe, PoToken generation and JavaScript
    /// signature/`n` deciphering; those extraction engines are not silently
    /// replaced with a fabricated URL here.
    func resolveStream(for track: MusicTrack) async throws -> ResolvedMusicStream {
        guard let videoID = track.videoID else { throw MusicRequestError.noPlayableStream }
        await ensureClientVersion()
        let version = "21.29.1" // IOS_RECENT in data/innertube/PlayerClient.kt
        let osVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let userAgent = "com.google.ios.youtube/\(version) (iPhone; U; CPU iPhone OS \(osVersion) like Mac OS X;)"
        let client: [String: Any] = [
            "clientName": "IOS",
            "clientVersion": version,
            "hl": languageCode,
            "gl": regionCode,
            "deviceMake": "Apple",
            "deviceModel": "iPhone"
        ]
        var playerClient = client
        if let visitorData { playerClient["visitorData"] = visitorData }
        let body: [String: Any] = [
            "context": ["client": playerClient],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        let response = try await postJSON(
            url: URL(string: "\(youtubeOrigin)/youtubei/v1/player?prettyPrint=false&hl=\(languageCode)")!,
            body: body,
            headers: [
                "Origin": youtubeOrigin,
                "Referer": "\(youtubeOrigin)/",
                "X-YouTube-Client-Name": "5",
                "X-YouTube-Client-Version": version,
                "User-Agent": userAgent
            ]
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
            let mime = (format["mimeType"] as? String ?? "").lowercased()
            return mime.hasPrefix("audio/")
        }
        let direct = audioFormats.compactMap { format -> (URL, Int, String)? in
            guard let rawURL = format["url"] as? String,
                  let url = URL(string: rawURL),
                  let mime = format["mimeType"] as? String else { return nil }
            let bitrate = (format["averageBitrate"] as? NSNumber)?.intValue
                ?? (format["bitrate"] as? NSNumber)?.intValue
                ?? 0
            return (url, bitrate, mime.lowercased())
        }
        guard let playable = direct
            .filter({ $0.2.contains("audio/mp4") || $0.2.contains("audio/aac") })
            .max(by: { $0.1 < $1.1 }) else {
            if audioFormats.contains(where: { $0["signatureCipher"] != nil || $0["cipher"] != nil }) {
                throw MusicRequestError.unsupportedFormat
            }
            throw MusicRequestError.noPlayableStream
        }
        return ResolvedMusicStream(
            url: playable.0,
            headers: [
                "User-Agent": userAgent,
                "Origin": youtubeOrigin,
                "Referer": "\(youtubeOrigin)/"
            ]
        )
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
