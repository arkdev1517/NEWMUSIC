import XCTest
@testable import BitChord

final class LRCParserTests: XCTestCase {
    func testParsesLineStampsAndSorts() {
        let lines = LRCParser.parse("""
        [00:10.50] Second line
        [00:05.25] First line
        """)
        XCTAssertEqual(lines.map(\.text), ["", "First line", "Second line"])
        XCTAssertEqual(lines[1].timeMs, 5_250)
        XCTAssertEqual(lines[2].timeMs, 10_500)
    }

    func testIntroGapOnlyWhenLongEnough() {
        let short = LRCParser.parse("[00:02.00] Soon")
        XCTAssertEqual(short.first?.text, "Soon")

        let long = LRCParser.parse("[00:09.00] Late start")
        XCTAssertEqual(long.first?.timeMs, 0)
        XCTAssertTrue(long.first?.isGap ?? false)
    }

    func testShortGapsAreDroppedLongGapsKept() {
        let lines = LRCParser.parse("""
        [00:01.00] One
        [00:02.00]
        [00:03.00] Two
        [00:04.00]
        [00:20.00] Three
        """)
        let texts = lines.map(\.text)
        // The 1s break before "Two" is not worth showing; the 16s break is.
        XCTAssertEqual(texts, ["One", "Two", "", "Three"])
    }

    func testMillisecondFraction() {
        let lines = LRCParser.parse("[01:02.345] Precise")
        XCTAssertEqual(lines.last?.timeMs, 62_345)
    }

    func testWordRunsGlueSyllablesAndTerminate() {
        let lines = LRCParser.parse("[00:01.00] <00:01.00>Hel<00:01.50>lo <00:02.00>world<00:03.00>")
        let line = lines.first { !$0.isGap }
        XCTAssertEqual(line?.text, "Hello world")
        XCTAssertEqual(line?.words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(line?.words.first?.startMs, 1_000)
        XCTAssertEqual(line?.words.last?.endMs, 3_000)
        XCTAssertTrue(line?.isWordSynced ?? false)
    }

    func testPlainLyricsHaveNoWordSync() {
        let lines = LRCParser.parse("[00:01.00] Plain line")
        XCTAssertFalse(lines.first { !$0.isGap }?.isWordSynced ?? true)
    }

    func testCleanerStripsYouTubeNoise() {
        XCTAssertEqual(
            LyricsQueryCleaner.clean("Tum Hi Ho (From \"Aashiqui 2\")"),
            "Tum Hi Ho"
        )
        XCTAssertEqual(
            LyricsQueryCleaner.clean("Song | Official Video"),
            "Song"
        )
        XCTAssertEqual(LyricsQueryCleaner.clean("Already Clean"), "Already Clean")
    }
}
