import CoreGraphics
import XCTest
@testable import BitChord

/// The now-playing screen's own measurements.
///
/// The player is a phone's screen: one column, the artwork on top of it and
/// the controls under it. A window wider than a phone — a Mac, an iPad in
/// landscape — must not stretch that column across the whole width, or the
/// scrubber, the transport and the action row end up a hand's width apart
/// and the artwork floats in the middle of them instead of lining up with
/// the titles under it.
final class PlayerLayoutTests: XCTestCase {
    func testAPhoneGetsAPhoneColumn() {
        let layout = PlayerLayout(in: CGSize(width: 393, height: 852))
        XCTAssertEqual(layout.columnWidth, 345, accuracy: 0.5)
        // The artwork is the column's width, so the two line up.
        XCTAssertEqual(layout.artworkSize, layout.columnWidth)
    }

    func testAWideWindowKeepsTheColumnNarrow() {
        let layout = PlayerLayout(in: CGSize(width: 1200, height: 800))
        XCTAssertLessThanOrEqual(layout.columnWidth, 460)
        XCTAssertGreaterThan(layout.columnWidth, 300)
    }

    func testTheColumnIsNeverNarrowerThanTheControlsNeed() {
        // A window too short for the artwork: the rows under it are what
        // matter, so the column keeps their width and the artwork gives
        // up the room.
        let layout = PlayerLayout(in: CGSize(width: 1200, height: 620))
        XCTAssertGreaterThanOrEqual(layout.columnWidth, 300)
    }

    func testAShortWindowGivesTheArtworkRoomToTheRows() {
        let tall = PlayerLayout(in: CGSize(width: 1200, height: 900))
        let short = PlayerLayout(in: CGSize(width: 1200, height: 620))
        XCTAssertLessThan(short.columnWidth, tall.columnWidth)
    }
}
