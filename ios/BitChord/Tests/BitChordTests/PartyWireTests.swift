import XCTest
@testable import BitChord

final class PartyWireTests: XCTestCase {
    func testCreateResponseDecodesServerPartyAndTokenWithoutLeakingIntoModels() throws {
        let payload: [String: Any] = [
            "code": "AB12CD",
            "token": "opaque-membership-token",
            "you": [
                "memberId": "member-1",
                "userId": "hashed-account-id",
                "displayName": "Listener",
                "avatarUrl": NSNull(),
                "isHost": true,
                "connected": false,
                "joinedAtMs": 1_757_630_000_000,
                "lastSeenMs": 1_757_630_000_000
            ],
            "party": [
                "code": "AB12CD",
                "createdAtMs": 1_757_630_000_000,
                "maxMembers": 5,
                "hostOnlyControl": true,
                "members": [[
                    "memberId": "member-1",
                    "userId": "hashed-account-id",
                    "displayName": "Listener",
                    "avatarUrl": NSNull(),
                    "isHost": true,
                    "connected": false,
                    "joinedAtMs": 1_757_630_000_000,
                    "lastSeenMs": 1_757_630_000_000
                ]],
                "playback": [
                    "seq": 3,
                    "track": [
                        "videoId": "video-1",
                        "title": "Song",
                        "artist": "Artist",
                        "thumbnailUrl": NSNull(),
                        "durationMs": 200_000,
                        "fromAutoplay": false
                    ],
                    "queueSeq": 2,
                    "queueLength": 1,
                    "queueIndex": 0,
                    "isPlaying": true,
                    "positionMs": 10_000,
                    "anchorMs": 1_757_630_000_350,
                    "effectivePositionMs": 10_000,
                    "updatedBy": "member-1",
                    "startedBy": "member-1",
                    "startedByName": "Listener",
                    "autoplayEnabled": false,
                    "updatedAtMs": 1_757_630_000_000
                ],
                "queue": [
                    "seq": 2,
                    "index": 0,
                    "items": [[
                        "videoId": "video-1",
                        "title": "Song",
                        "artist": "Artist",
                        "thumbnailUrl": NSNull(),
                        "durationMs": 200_000,
                        "fromAutoplay": false
                    ]]
                ],
                "serverMs": 1_757_630_000_100
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let membership = try JSONDecoder().decode(PartyMembership.self, from: data)

        XCTAssertEqual(membership.code, "AB12CD")
        XCTAssertEqual(membership.you.memberId, "member-1")
        XCTAssertEqual(membership.party.playback.track?.videoId, "video-1")
        XCTAssertEqual(membership.party.queue.items.count, 1)
        XCTAssertTrue(membership.party.hostOnlyControl)
        XCTAssertEqual(membership.serverMs, membership.party.serverMs)
    }

    func testOlderPartySnapshotDefaultsHostOnlyControlToOff() throws {
        let data = Data(#"{"code":"ZX91QW","members":[],"playback":{},"queue":{}}"#.utf8)

        let party = try JSONDecoder().decode(PartySnapshot.self, from: data)

        XCTAssertFalse(party.hostOnlyControl)
        XCTAssertEqual(party.maxMembers, 5)
        XCTAssertEqual(party.playback.queueIndex, -1)
        XCTAssertEqual(party.queue.index, -1)
    }

    func testBackendErrorCodeUsesTheErrorWireKey() throws {
        let data = Data(#"{"status":403,"error":"host_only","message":"Only the host may do that."}"#.utf8)

        let error = try JSONDecoder().decode(PartyWireError.self, from: data)

        XCTAssertEqual(error.code, "host_only")
        XCTAssertEqual(error.message, "Only the host may do that.")
    }
}
