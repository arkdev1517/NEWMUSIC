import Foundation

struct PartyTrack: Codable, Hashable, Sendable, Identifiable {
    var videoId: String
    var title: String
    var artist: String
    var thumbnailUrl: String?
    var durationMs: Int64?
    var fromAutoplay: Bool
    var id: String { videoId }

    init(videoId: String, title: String = "", artist: String = "", thumbnailUrl: String? = nil, durationMs: Int64? = nil, fromAutoplay: Bool = false) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumbnailUrl = thumbnailUrl
        self.durationMs = durationMs
        self.fromAutoplay = fromAutoplay
    }
}

struct PartyMember: Codable, Hashable, Sendable, Identifiable {
    var memberId: String
    var userId: String
    var displayName: String
    var avatarUrl: String?
    var isHost: Bool
    var connected: Bool
    var joinedAtMs: Int64
    var lastSeenMs: Int64
    var id: String { memberId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try container.decodeIfPresent(String.self, forKey: .memberId) ?? ""
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Listener"
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        isHost = try container.decodeIfPresent(Bool.self, forKey: .isHost) ?? false
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        joinedAtMs = try container.decodeIfPresent(Int64.self, forKey: .joinedAtMs) ?? 0
        lastSeenMs = try container.decodeIfPresent(Int64.self, forKey: .lastSeenMs) ?? 0
    }
}

struct PartyPlayback: Codable, Hashable, Sendable {
    var seq: Int64
    var track: PartyTrack?
    var queueSeq: Int64
    var queueLength: Int
    var queueIndex: Int
    var isPlaying: Bool
    var positionMs: Int64
    var anchorMs: Int64
    var effectivePositionMs: Int64
    var updatedBy: String?
    var startedBy: String?
    var startedByName: String?
    var autoplayEnabled: Bool
    var updatedAtMs: Int64

    init() {
        seq = 0
        track = nil
        queueSeq = 0
        queueLength = 0
        queueIndex = -1
        isPlaying = false
        positionMs = 0
        anchorMs = 0
        effectivePositionMs = 0
        updatedBy = nil
        startedBy = nil
        startedByName = nil
        autoplayEnabled = false
        updatedAtMs = 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        track = try container.decodeIfPresent(PartyTrack.self, forKey: .track)
        queueSeq = try container.decodeIfPresent(Int64.self, forKey: .queueSeq) ?? 0
        queueLength = try container.decodeIfPresent(Int.self, forKey: .queueLength) ?? 0
        queueIndex = try container.decodeIfPresent(Int.self, forKey: .queueIndex) ?? -1
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        positionMs = try container.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
        anchorMs = try container.decodeIfPresent(Int64.self, forKey: .anchorMs) ?? 0
        effectivePositionMs = try container.decodeIfPresent(Int64.self, forKey: .effectivePositionMs) ?? positionMs
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy)
        startedBy = try container.decodeIfPresent(String.self, forKey: .startedBy)
        startedByName = try container.decodeIfPresent(String.self, forKey: .startedByName)
        autoplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoplayEnabled) ?? false
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
    }
}

struct PartyQueue: Codable, Hashable, Sendable {
    var seq: Int64
    var index: Int
    var items: [PartyTrack]

    init(seq: Int64, index: Int, items: [PartyTrack]) {
        self.seq = seq
        self.index = index
        self.items = items
    }

    init() {
        seq = 0
        index = -1
        items = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? -1
        items = try container.decodeIfPresent([PartyTrack].self, forKey: .items) ?? []
    }
}

struct PartySnapshot: Codable, Hashable, Sendable {
    var code: String
    var createdAtMs: Int64
    var maxMembers: Int
    var hostOnlyControl: Bool
    var members: [PartyMember]
    var playback: PartyPlayback
    var queue: PartyQueue
    var serverMs: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        maxMembers = try container.decodeIfPresent(Int.self, forKey: .maxMembers) ?? 5
        hostOnlyControl = try container.decodeIfPresent(Bool.self, forKey: .hostOnlyControl) ?? false
        members = try container.decodeIfPresent([PartyMember].self, forKey: .members) ?? []
        playback = try container.decodeIfPresent(PartyPlayback.self, forKey: .playback) ?? PartyPlayback()
        queue = try container.decodeIfPresent(PartyQueue.self, forKey: .queue) ?? PartyQueue()
        serverMs = try container.decodeIfPresent(Int64.self, forKey: .serverMs) ?? 0
    }
}

struct PartyPreview: Codable, Hashable, Sendable {
    var code: String
    var hostName: String
    var memberCount: Int
    var maxMembers: Int
    var isFull: Bool
    var members: [PartyPreviewMember]
}

struct PartyPreviewMember: Codable, Hashable, Sendable, Identifiable {
    var displayName: String
    var avatarUrl: String?
    var isHost: Bool
    var id: String { "\(displayName)|\(avatarUrl ?? "")" }
}

struct PartyMembership: Decodable, Sendable {
    var code: String
    var token: String
    var you: PartyMember
    var party: PartySnapshot
    var serverMs: Int64

    private enum CodingKeys: String, CodingKey { case code, token, you, party, serverMs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        token = try container.decode(String.self, forKey: .token)
        you = try container.decode(PartyMember.self, forKey: .you)
        party = try container.decode(PartySnapshot.self, forKey: .party)
        serverMs = try container.decodeIfPresent(Int64.self, forKey: .serverMs) ?? party.serverMs
    }
}

struct PartyActivity: Codable, Hashable, Sendable, Identifiable {
    var action: String
    var by: String
    var atMs: Int64
    var detail: String
    var id: String { "\(atMs)-\(by)-\(action)" }
}

struct PartyJoinRequest: Encodable, Sendable {
    var userId: String
    var deviceId: String
    var displayName: String
    var avatarUrl: String?
    var maxMembers: Int?
    var autoplayEnabled: Bool?
}

struct PartyWireError: Decodable, Error, LocalizedError, Sendable {
    var code: String
    var message: String
    var errorDescription: String? { message.isEmpty ? "Listen Together request failed." : message }

    private enum CodingKeys: String, CodingKey {
        case code = "error"
        case message
    }
}
