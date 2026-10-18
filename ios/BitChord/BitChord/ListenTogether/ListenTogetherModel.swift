import Combine
import CryptoKit
import Foundation

@MainActor
final class ListenTogetherModel: ObservableObject {
    enum ConnectionState: String {
        case offline
        case connecting
        case live
        case reconnecting
    }

    static let defaultServerURL = "https://bitchord-listen-together.onrender.com"

    @Published var serverURL: String
    @Published var joinCode = ""
    @Published private(set) var party: PartySnapshot?
    @Published private(set) var you: PartyMember?
    @Published private(set) var preview: PartyPreview?
    @Published private(set) var queue = PartyQueue(seq: 0, index: -1, items: [])
    @Published private(set) var activity: [PartyActivity] = []
    @Published private(set) var connection: ConnectionState = .offline
    @Published private(set) var isBusy = false
    @Published private(set) var isCheckingServer = false
    @Published private(set) var serverLatencyMs: Int64?
    @Published private(set) var pendingInviteServerURL: String?
    @Published var errorMessage: String?

    var onPlaybackUpdate: ((PartyPlayback, TimeInterval) -> Void)?

    var isInParty: Bool { party != nil && you != nil }
    var hasPendingInvite: Bool {
        guard isInParty, joinCode.count == 6 else { return false }
        return joinCode != party?.code || pendingInviteServerURL != nil
    }
    var mayControl: Bool { party?.hostOnlyControl != true || you?.isHost == true }
    var currentNickname: String { defaults.string(forKey: "bitchord-listen-together-nickname-v1") ?? "" }
    var onlineStatus: String {
        if let serverLatencyMs { return "Online · \(serverLatencyMs) ms" }
        return isCheckingServer ? "Checking server…" : "Server not checked"
    }
    var partyPositionSeconds: TimeInterval? {
        guard let playback = party?.playback else { return nil }
        let localNow = monotonicNowMs()
        let position: Int64
        if playback.isPlaying, let clockOffsetMs {
            let serverNow = localNow + clockOffsetMs
            position = max(0, playback.positionMs + max(0, serverNow - playback.anchorMs))
        } else if playback.isPlaying {
            position = max(0, playback.effectivePositionMs)
        } else {
            position = max(0, playback.positionMs)
        }
        let clamped = playback.track?.durationMs.map { min(position, $0) } ?? position
        return TimeInterval(clamped) / 1000
    }

    private let musicService: any MusicService
    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private let client = ListenTogetherClient()
    private let serverURLKey = "bitchord-listen-together-server-v1"
    private let deviceIDKey = "bitchord-listen-together-device-id-v1"
    private let nicknameKey = "bitchord-listen-together-nickname-v1"
    private let savedCodeKey = "bitchord-listen-together-code-v1"
    private let savedMemberKey = "bitchord-listen-together-member-v1"
    private let savedTokenKey = "bitchord-listen-together-token-v1"
    private let savedServerKey = "bitchord-listen-together-active-server-v1"

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isRestoringParty = false
    private var connectionGeneration = UUID()
    private var lastPlaybackSequence: Int64 = -1
    private var clockSamples: [(offset: Int64, roundTrip: Int64, takenAt: Int64)] = []
    private var clockOffsetMs: Int64?

    init(musicService: any MusicService, credentials: any CredentialStore, defaults: UserDefaults = .standard) {
        self.musicService = musicService
        self.credentials = credentials
        self.defaults = defaults
        serverURL = defaults.string(forKey: "bitchord-listen-together-server-v1") ?? Self.defaultServerURL
    }

    func setServerURL(_ rawValue: String) {
        serverURL = rawValue
        defaults.set(rawValue, forKey: serverURLKey)
        serverLatencyMs = nil
    }

    /// Accepts the repository's `bitchord://party/<CODE>?server=<HTTPS URL>` invite.
    /// A live/saved membership is left on its current server until the user chooses
    /// to leave, then the invite's server becomes active.
    @discardableResult
    func openInvite(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "bitchord",
              components.host?.lowercased() == "party" else { return false }
        let pathCode = components.path.split(separator: "/").last.map(String.init)
        let queryCode = components.queryItems?.first(where: { $0.name.lowercased() == "code" })?.value
        guard let code = normalizedCode(pathCode ?? queryCode ?? "") else { return false }
        pendingInviteServerURL = nil

        let inviteServer = components.queryItems?.first(where: { $0.name.lowercased() == "server" })?.value
        if let inviteServer, !inviteServer.isEmpty {
            let isValidServer = normalizedServerURL(from: inviteServer) != nil
            let hasSavedMembership = defaults.string(forKey: savedCodeKey) != nil
                && credentials.string(for: savedTokenKey) != nil
            if isInParty || isRestoringParty || hasSavedMembership {
                pendingInviteServerURL = inviteServer
            } else {
                setServerURL(inviteServer)
            }
            joinCode = code
            preview = nil
            if !isValidServer { return true }
        }
        joinCode = code
        preview = nil
        errorMessage = nil
        return true
    }

    func probeServer() async {
        guard let base = normalizedServerURL() else { return }
        isCheckingServer = true
        defer { isCheckingServer = false }
        let start = monotonicNowMs()
        do {
            _ = try await client.serverTime(baseURL: base)
            serverLatencyMs = max(0, monotonicNowMs() - start)
        } catch {
            serverLatencyMs = nil
            errorMessage = error.localizedDescription
        }
    }

    func previewParty() async {
        guard let code = normalizedCode(joinCode) else {
            errorMessage = "Enter a six-character party code."
            return
        }
        guard let base = normalizedServerURL() else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            preview = try await client.preview(code: code, baseURL: base)
            joinCode = code
        } catch {
            errorMessage = error.localizedDescription
            preview = nil
        }
    }

    func createParty(maxMembers: Int = 5, autoplayEnabled: Bool = false) async {
        guard let base = normalizedServerURL() else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let identity = try await joinIdentity(maxMembers: maxMembers, autoplayEnabled: autoplayEnabled)
            let start = monotonicNowMs()
            let membership = try await client.createParty(identity, baseURL: base)
            recordClockSample(sentAt: start, serverMs: membership.party.serverMs, receivedAt: monotonicNowMs())
            try saveMembership(membership, server: base.absoluteString)
            accept(membership)
            await connectSocket()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func joinParty() async {
        guard let code = normalizedCode(joinCode) else {
            errorMessage = "Enter a six-character party code."
            return
        }
        guard let base = normalizedServerURL() else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let identity = try await joinIdentity()
            let start = monotonicNowMs()
            let membership = try await client.joinParty(code: code, body: identity, baseURL: base)
            recordClockSample(sentAt: start, serverMs: membership.party.serverMs, receivedAt: monotonicNowMs())
            try saveMembership(membership, server: base.absoluteString)
            accept(membership)
            preview = nil
            await connectSocket()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreSavedParty() async {
        guard party == nil, !isRestoringParty,
              let code = defaults.string(forKey: savedCodeKey),
              let memberID = defaults.string(forKey: savedMemberKey),
              let token = credentials.string(for: savedTokenKey) else { return }
        isRestoringParty = true
        defer { isRestoringParty = false }
        if let savedServer = defaults.string(forKey: savedServerKey), !savedServer.isEmpty {
            serverURL = savedServer
        }
        guard let base = normalizedServerURL() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let start = monotonicNowMs()
            let snapshot = try await client.snapshot(code: code, token: token, baseURL: base)
            recordClockSample(sentAt: start, serverMs: snapshot.serverMs, receivedAt: monotonicNowMs())
            guard let localMember = snapshot.members.first(where: { $0.memberId == memberID }) else {
                throw ListenTogetherFailure(code: "membership_missing", message: "This device is no longer in that party.", statusCode: nil)
            }
            party = snapshot
            you = localMember
            if joinCode.isEmpty { joinCode = code }
            queue = snapshot.queue
            lastPlaybackSequence = snapshot.playback.seq
            await connectSocket()
        } catch {
            errorMessage = error.localizedDescription
            clearSavedMembership()
            applyPendingInviteServer()
        }
    }

    func leaveParty() async {
        guard let activeParty = party,
              let token = credentials.string(for: savedTokenKey),
              let base = normalizedServerURL() else {
            clearPartyState()
            applyPendingInviteServer()
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.leave(code: activeParty.code, token: token, baseURL: base)
        } catch {
            errorMessage = error.localizedDescription
        }
        closeConnection()
        clearSavedMembership()
        clearPartyState()
        applyPendingInviteServer()
    }

    func sendControl(_ action: String, fields: [String: Any] = [:]) async {
        guard isInParty, mayControl, let socket else {
            if isInParty && !mayControl { errorMessage = "Only the host can control playback in this party." }
            return
        }
        var frame: [String: Any] = ["type": "control", "action": action]
        for (key, value) in fields { frame[key] = value }
        do { try await send(frame, on: socket) }
        catch { errorMessage = error.localizedDescription }
    }

    func setSharedTrack(_ track: MusicTrack, queue tracks: [MusicTrack], queueIndex: Int) async {
        guard isInParty, mayControl else { return }
        let sharedQueue = tracks.compactMap { self.partyTrack(from: $0) }
        if !sharedQueue.isEmpty {
            await sendControl("setQueue", fields: ["queue": sharedQueue.map(wireTrack), "queueIndex": queueIndex])
        }
        guard let current = partyTrack(from: track) else { return }
        await sendControl("setTrack", fields: [
            "track": wireTrack(current),
            "queueIndex": queueIndex,
            "positionMs": 0,
            "isPlaying": true
        ])
    }

    func shareSeek(positionMs: Int64) async {
        await sendControl("seek", fields: ["positionMs": max(0, positionMs)])
    }

    func updateNickname(_ value: String) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: nicknameKey)
    }

    private func joinIdentity(maxMembers: Int? = nil, autoplayEnabled: Bool? = nil) async throws -> PartyJoinRequest {
        guard credentials.string(for: SessionCredential.youtubeCookie) != nil else {
            throw MusicRequestError.signInRequired
        }
        let account = try await musicService.account()
        let identitySeed = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stableIdentity = identitySeed.isEmpty ? account.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : identitySeed
        guard !stableIdentity.isEmpty else {
            throw ListenTogetherFailure(code: "missing_identity", message: "YouTube Music did not provide an account identity.", statusCode: nil)
        }
        let hash = SHA256.hash(data: Data(stableIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let deviceID = defaults.string(forKey: deviceIDKey) ?? UUID().uuidString.lowercased()
        defaults.set(deviceID, forKey: deviceIDKey)
        let nickname = defaults.string(forKey: nicknameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = nickname.isEmpty ? account.name : nickname
        return PartyJoinRequest(
            userId: String(hash.prefix(32)),
            deviceId: deviceID,
            displayName: name,
            avatarUrl: account.artworkURL,
            maxMembers: maxMembers,
            autoplayEnabled: autoplayEnabled
        )
    }

    private func saveMembership(_ membership: PartyMembership, server: String) throws {
        try credentials.set(membership.token, for: savedTokenKey)
        defaults.set(membership.code, forKey: savedCodeKey)
        defaults.set(membership.you.memberId, forKey: savedMemberKey)
        defaults.set(server, forKey: savedServerKey)
    }

    private func accept(_ membership: PartyMembership) {
        party = membership.party
        you = membership.you
        joinCode = membership.code
        pendingInviteServerURL = nil
        queue = membership.party.queue
        lastPlaybackSequence = membership.party.playback.seq
        activity = []
        connection = .connecting
        notifyPlayback()
    }

    private func connectSocket() async {
        guard let activeParty = party,
              let token = credentials.string(for: savedTokenKey),
              let base = normalizedServerURL() else { return }
        closeSocketOnly()
        connectionGeneration = UUID()
        let generation = connectionGeneration
        do {
            let newSocket = try await client.webSocket(code: activeParty.code, token: token, baseURL: base)
            socket = newSocket
            connection = .connecting
            newSocket.resume()
            startPingLoop(on: newSocket, generation: generation)
            receiveTask = Task { [weak self] in
                await self?.readMessages(from: newSocket, generation: generation)
            }
        } catch {
            errorMessage = error.localizedDescription
            scheduleReconnect()
        }
    }

    private func startPingLoop(on socket: URLSessionWebSocketTask, generation: UUID) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connectionGeneration == generation else { return }
                let sentAt = self.monotonicNowMs()
                do {
                    try await self.send(["type": "ping", "clientMs": sentAt], on: socket)
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private func readMessages(from socket: URLSessionWebSocketTask, generation: UUID) async {
        do {
            while !Task.isCancelled, connectionGeneration == generation {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                handleFrame(data, generation: generation)
            }
        } catch {
            guard connectionGeneration == generation else { return }
            connection = .reconnecting
            if !(error is CancellationError) { errorMessage = "Party connection interrupted. Reconnecting…" }
            scheduleReconnect()
        }
    }

    private func handleFrame(_ data: Data, generation: UUID) {
        guard connectionGeneration == generation,
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = frame["type"] as? String else { return }
        switch type {
        case "welcome":
            if let partyObject = frame["party"], let decoded = decode(PartySnapshot.self, from: partyObject) {
                party = decoded
                queue = decoded.queue
                lastPlaybackSequence = decoded.playback.seq
                notifyPlayback()
            }
            if let youObject = frame["you"], let decoded = decode(PartyMember.self, from: youObject) { you = decoded }
            if let serverMs = (frame["serverMs"] as? NSNumber)?.int64Value {
                recordClockSample(sentAt: monotonicNowMs(), serverMs: serverMs, receivedAt: monotonicNowMs())
            }
            connection = .live
        case "state":
            guard let raw = frame["playback"], let playback = decode(PartyPlayback.self, from: raw) else { return }
            if playback.seq > lastPlaybackSequence {
                lastPlaybackSequence = playback.seq
                if var updated = party {
                    updated.playback = playback
                    if let serverMs = (frame["serverMs"] as? NSNumber)?.int64Value { updated.serverMs = serverMs }
                    party = updated
                }
                if playback.queueSeq > queue.seq { requestQueueSync() }
                notifyPlayback()
            }
        case "queue":
            if let raw = frame["queue"], let decoded = decode(PartyQueue.self, from: raw) {
                if decoded.seq >= queue.seq {
                    queue = decoded
                    if var updated = party { updated.queue = decoded; party = updated }
                    notifyPlayback()
                }
            }
        case "members":
            if let raw = frame["members"], let decoded = decode([PartyMember].self, from: raw), var updated = party {
                updated.members = decoded
                updated.maxMembers = (frame["maxMembers"] as? NSNumber)?.intValue ?? updated.maxMembers
                updated.hostOnlyControl = (frame["hostOnlyControl"] as? Bool) ?? updated.hostOnlyControl
                party = updated
                if let memberID = you?.memberId { you = decoded.first(where: { $0.memberId == memberID }) ?? you }
            }
        case "pong":
            guard let clientMs = (frame["clientMs"] as? NSNumber)?.int64Value,
                  let serverMs = (frame["serverMs"] as? NSNumber)?.int64Value else { return }
            recordClockSample(sentAt: clientMs, serverMs: serverMs, receivedAt: monotonicNowMs())
            notifyPlayback()
        case "activity":
            let activity = PartyActivity(
                action: frame["action"] as? String ?? "",
                by: frame["by"] as? String ?? "Listener",
                atMs: (frame["atMs"] as? NSNumber)?.int64Value ?? monotonicNowMs(),
                detail: frame["detail"] as? String ?? ""
            )
            self.activity.insert(activity, at: 0)
            self.activity = Array(self.activity.prefix(50))
        case "error":
            errorMessage = (frame["message"] as? String) ?? (frame["error"] as? String) ?? "The party server rejected an action."
        case "bye":
            let reason = frame["reason"] as? String ?? "left"
            errorMessage = reason == "kicked" ? "You were removed from this party." : nil
            closeConnection()
            clearSavedMembership()
            clearPartyState()
        default:
            break
        }
    }

    private func notifyPlayback() {
        guard let playback = party?.playback, let position = partyPositionSeconds else { return }
        onPlaybackUpdate?(playback, position)
    }

    private func recordClockSample(sentAt: Int64, serverMs: Int64, receivedAt: Int64) {
        let rtt = max(0, receivedAt - sentAt)
        let midpoint = sentAt + rtt / 2
        clockSamples.append((serverMs - midpoint, rtt, receivedAt))
        clockSamples = Array(clockSamples.suffix(12))
        let cutoff = receivedAt - 120_000
        let recent = clockSamples.filter { $0.takenAt >= cutoff }
        if let best = (recent.isEmpty ? clockSamples : recent).min(by: { $0.roundTrip < $1.roundTrip }) {
            clockOffsetMs = best.offset
        }
    }

    private func requestQueueSync() {
        guard let socket else { return }
        Task { try? await send(["type": "syncQueue"], on: socket) }
    }

    private func send(_ frame: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        guard JSONSerialization.isValidJSONObject(frame) else {
            throw ListenTogetherFailure(code: "invalid_frame", message: "Could not encode the party message.", statusCode: nil)
        }
        let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ListenTogetherFailure(code: "invalid_frame", message: "Could not encode the party message.", statusCode: nil)
        }
        try await socket.send(.string(text))
    }

    private func scheduleReconnect() {
        guard isInParty, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            let delays: [UInt64] = [1, 2, 4, 8, 12]
            for seconds in delays {
                guard let self, !Task.isCancelled, self.isInParty else { return }
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled else { return }
                await self.connectSocket()
                if self.connection == .connecting || self.connection == .live {
                    self.reconnectTask = nil
                    return
                }
            }
            self?.reconnectTask = nil
        }
    }

    private func closeConnection() {
        connectionGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        closeSocketOnly()
        connection = .offline
        clockOffsetMs = nil
        clockSamples = []
        lastPlaybackSequence = -1
    }

    private func closeSocketOnly() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func clearSavedMembership() {
        try? credentials.set(nil, for: savedTokenKey)
        defaults.removeObject(forKey: savedCodeKey)
        defaults.removeObject(forKey: savedMemberKey)
        defaults.removeObject(forKey: savedServerKey)
    }

    private func applyPendingInviteServer() {
        guard let inviteServer = pendingInviteServerURL else { return }
        pendingInviteServerURL = nil
        setServerURL(inviteServer)
    }

    private func clearPartyState() {
        party = nil
        you = nil
        queue = PartyQueue(seq: 0, index: -1, items: [])
        activity = []
        preview = nil
    }

    private func normalizedServerURL() -> URL? {
        normalizedServerURL(from: serverURL)
    }

    private func normalizedServerURL(from rawValue: String) -> URL? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty,
              var components = URLComponents(string: cleaned),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            errorMessage = "Enter a secure HTTPS server address with no path or query."
            return nil
        }
        components.path = ""
        guard let url = components.url else {
            errorMessage = "The party server address is invalid."
            return nil
        }
        return url
    }

    private func normalizedCode(_ raw: String) -> String? {
        let filtered = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        let code = filtered.map { character -> Character in
            switch character {
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        }
        let result = String(code)
        return result.count == 6 ? result : nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func partyTrack(from track: MusicTrack) -> PartyTrack? {
        guard let videoID = track.videoID else { return nil }
        let duration = track.durationSeconds.map { Int64($0 * 1000) }
        return PartyTrack(videoId: videoID, title: track.title, artist: track.artist, thumbnailUrl: track.artworkURL, durationMs: duration)
    }

    private func wireTrack(_ track: PartyTrack) -> [String: Any] {
        var value: [String: Any] = [
            "videoId": track.videoId,
            "title": track.title,
            "artist": track.artist,
            "fromAutoplay": track.fromAutoplay
        ]
        if let thumbnailUrl = track.thumbnailUrl { value["thumbnailUrl"] = thumbnailUrl }
        if let durationMs = track.durationMs { value["durationMs"] = durationMs }
        return value
    }

    private func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
