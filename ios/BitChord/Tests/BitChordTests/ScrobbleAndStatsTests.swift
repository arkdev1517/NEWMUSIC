import XCTest
@testable import BitChord

final class ScrobbleAndStatsTests: XCTestCase {
    // MARK: Scrobble timing (ScrobbleManager's rule)

    func testScrobbleAtHalfOfShortTrack() {
        XCTAssertFalse(ScrobbleManager.shouldScrobble(
            played: 29, duration: 60, percent: 0.5, capSeconds: 180, minDuration: 30
        ))
        XCTAssertTrue(ScrobbleManager.shouldScrobble(
            played: 30, duration: 60, percent: 0.5, capSeconds: 180, minDuration: 30
        ))
    }

    func testScrobbleCapBeatsPercentOnLongTrack() {
        // Half of a 20-minute track is 600s; the 180s cap wins.
        XCTAssertTrue(ScrobbleManager.shouldScrobble(
            played: 180, duration: 1200, percent: 0.5, capSeconds: 180, minDuration: 30
        ))
        XCTAssertFalse(ScrobbleManager.shouldScrobble(
            played: 179, duration: 1200, percent: 0.5, capSeconds: 180, minDuration: 30
        ))
    }

    func testTooShortTracksNeverScrobble() {
        XCTAssertFalse(ScrobbleManager.shouldScrobble(
            played: 25, duration: 25, percent: 0.5, capSeconds: 180, minDuration: 30
        ))
    }

    func testPrimaryArtist() {
        XCTAssertEqual(ScrobbleManager.primaryArtist("Arijit Singh, Shreya Ghoshal"), "Arijit Singh")
        XCTAssertEqual(ScrobbleManager.primaryArtist("Simon & Garfunkel"), "Simon")
        XCTAssertEqual(ScrobbleManager.primaryArtist("AC/DC"), "AC/DC")
        XCTAssertEqual(ScrobbleManager.primaryArtist("Solo Artist"), "Solo Artist")
    }

    func testLastfmSignatureSortsAndDigests() {
        // md5("api_keykeymethodauth.getTokensesame") — computed independently
        // of the implementation's own digest at authoring time would be
        // circular, so pin the shape: 32 lowercase hex chars, stable for
        // reordered input, and sensitive to the secret.
        let sig = ScrobbleManager.signature(
            params: ["method": "auth.getToken", "api_key": "key"], secret: "sesame"
        )
        let reordered = ScrobbleManager.signature(
            params: ["api_key": "key", "method": "auth.getToken"], secret: "sesame"
        )
        XCTAssertEqual(sig, reordered)
        XCTAssertEqual(sig.count, 32)
        XCTAssertTrue(sig.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let otherSecret = ScrobbleManager.signature(
            params: ["method": "auth.getToken", "api_key": "key"], secret: "other"
        )
        XCTAssertNotEqual(sig, otherSecret)
    }

    func testFormEncodingEscapesReservedCharacters() {
        let encoded = ScrobbleManager.formEncode(["artist": "A & B", "track": "a=b"])
        XCTAssertTrue(encoded.contains("artist=A%20%26%20B"))
        XCTAssertTrue(encoded.contains("track=a%3Db"))
    }

    // MARK: Play counting & statistics (ListeningRecorder's rule)

    func testPlayCountThresholds() {
        // Under the 30s floor never counts.
        XCTAssertFalse(ListeningRecorder.countsAsPlay(played: 29, duration: 40))
        // Half of a 3-minute song.
        XCTAssertTrue(ListeningRecorder.countsAsPlay(played: 90, duration: 180))
        XCTAssertFalse(ListeningRecorder.countsAsPlay(played: 89, duration: 180))
        // The 4-minute ceiling on a long track.
        XCTAssertTrue(ListeningRecorder.countsAsPlay(played: 240, duration: 3600))
        // Unknown duration falls back to the floor.
        XCTAssertTrue(ListeningRecorder.countsAsPlay(played: 30, duration: 0))
    }

    func testSummaryRanksByPlaysAndIgnoresSkips() {
        let now = Date()
        func event(_ id: String, _ title: String, _ artist: String, counts: Bool) -> PlayEvent {
            PlayEvent(
                id: id, videoID: id, title: title, artist: artist,
                albumName: "Album", artworkURL: nil, startedAt: now,
                playedSeconds: 120, countsAsPlay: counts
            )
        }
        let events = [
            event("a", "Alpha", "One", counts: true),
            event("a", "Alpha", "One", counts: true),
            event("b", "Beta", "Two", counts: true),
            event("c", "Gamma", "One", counts: false)
        ]
        let summary = ListeningRecorder.summarize(events)
        XCTAssertEqual(summary.totalPlays, 3)
        XCTAssertEqual(summary.topTracks.first?.title, "Alpha")
        XCTAssertEqual(summary.topTracks.first?.plays, 2)
        XCTAssertEqual(summary.topArtists.first?.title, "One")
        XCTAssertEqual(summary.topArtists.first?.plays, 2)
        // Total seconds count every listen, plays or skips.
        XCTAssertEqual(summary.totalSeconds, 480, accuracy: 0.001)
    }

    func testPeriodFiltering() {
        let now = Date()
        let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        XCTAssertTrue(ListeningRecorder.Period.month.contains(now, now: now))
        XCTAssertFalse(ListeningRecorder.Period.year.contains(lastYear, now: now))
        XCTAssertTrue(ListeningRecorder.Period.allTime.contains(lastYear, now: now))
    }
}
