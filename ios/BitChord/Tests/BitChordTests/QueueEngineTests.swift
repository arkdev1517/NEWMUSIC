import XCTest
@testable import BitChord

final class QueueEngineTests: XCTestCase {
    private func track(_ id: String) -> MusicTrack {
        MusicTrack(videoID: id, title: id, artist: "Artist", artworkURL: nil, localFileName: nil)
    }

    private func engine(count: Int, start: Int = 0) -> QueueEngine {
        var engine = QueueEngine()
        engine.setQueue((0..<count).map { track("t\($0)") }, startIndex: start)
        return engine
    }

    func testAdvanceWalksAndFinishes() {
        var engine = engine(count: 3)
        XCTAssertEqual(engine.currentTrack?.videoID, "t0")
        XCTAssertEqual(engine.advance(manual: true), .playTrack)
        XCTAssertEqual(engine.currentTrack?.videoID, "t1")
        XCTAssertEqual(engine.advance(manual: true), .playTrack)
        XCTAssertEqual(engine.advance(manual: true), .finished)
    }

    func testRepeatAllWraps() {
        var engine = engine(count: 2, start: 1)
        engine.repeatMode = .all
        XCTAssertEqual(engine.advance(manual: false), .playTrack)
        XCTAssertEqual(engine.currentTrack?.videoID, "t0")
    }

    func testRepeatOneOnlyOnAutoAdvance() {
        var engine = engine(count: 2)
        engine.repeatMode = .one
        XCTAssertEqual(engine.advance(manual: false), .restartCurrent)
        XCTAssertEqual(engine.currentTrack?.videoID, "t0")
        XCTAssertEqual(engine.advance(manual: true), .playTrack)
        XCTAssertEqual(engine.currentTrack?.videoID, "t1")
    }

    func testShufflePinsCurrentAndRestoresOrder() {
        var engine = engine(count: 6, start: 2)
        engine.setShuffle(true)
        XCTAssertEqual(engine.currentTrack?.videoID, "t2")
        XCTAssertEqual(Set(engine.effectiveQueue.map(\.videoID)), Set((0..<6).map { "t\($0)" }))
        engine.setShuffle(false)
        XCTAssertEqual(engine.effectiveQueue.map(\.videoID), (0..<6).map { "t\($0)" })
        XCTAssertEqual(engine.currentTrack?.videoID, "t2")
        XCTAssertEqual(engine.effectiveIndex, 2)
    }

    func testPlayNextInsertsAfterCurrent() {
        var engine = engine(count: 3)
        engine.insertNext(track("next"))
        XCTAssertEqual(engine.effectiveQueue.map(\.videoID), ["t0", "next", "t1", "t2"])
        XCTAssertEqual(engine.advance(manual: true), .playTrack)
        XCTAssertEqual(engine.currentTrack?.videoID, "next")
    }

    func testRemoveBeforeCurrentKeepsPlayingTrack() {
        var engine = engine(count: 4, start: 2)
        let wasCurrent = engine.remove(atEffectiveIndex: 0)
        XCTAssertFalse(wasCurrent)
        XCTAssertEqual(engine.currentTrack?.videoID, "t2")
        XCTAssertEqual(engine.effectiveIndex, 1)
        XCTAssertEqual(engine.effectiveQueue.map(\.videoID), ["t1", "t2", "t3"])
    }

    func testRemoveCurrentReportsAndPointsAtSuccessor() {
        var engine = engine(count: 3, start: 1)
        let wasCurrent = engine.remove(atEffectiveIndex: 1)
        XCTAssertTrue(wasCurrent)
        XCTAssertEqual(engine.currentTrack?.videoID, "t2")
    }

    func testMoveKeepsCurrentTrack() {
        var engine = engine(count: 4, start: 1)
        engine.move(fromEffectiveIndex: 3, toEffectiveIndex: 0)
        XCTAssertEqual(engine.effectiveQueue.map(\.videoID), ["t3", "t0", "t1", "t2"])
        XCTAssertEqual(engine.currentTrack?.videoID, "t1")
        XCTAssertEqual(engine.effectiveIndex, 2)
    }

    func testPreviousStopsAtStart() {
        var engine = engine(count: 2)
        XCTAssertFalse(engine.goPrevious())
        _ = engine.advance(manual: true)
        XCTAssertTrue(engine.goPrevious())
        XCTAssertEqual(engine.currentTrack?.videoID, "t0")
    }

    func testPreservingOrderIgnoresShuffleFlag() {
        var engine = QueueEngine()
        engine.shuffleEnabled = true
        engine.setQueuePreservingOrder((0..<4).map { track("t\($0)") }, startIndex: 2)
        XCTAssertEqual(engine.effectiveQueue.map(\.videoID), ["t0", "t1", "t2", "t3"])
        XCTAssertEqual(engine.effectiveIndex, 2)
    }
}
