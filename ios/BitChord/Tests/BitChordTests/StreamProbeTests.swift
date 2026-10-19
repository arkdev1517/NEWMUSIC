import XCTest
@testable import BitChord

/// The range the stream probe reads.
///
/// A URL that only serves its opening is no good to the player, which asks
/// for megabytes: some clients' URLs serve the first megabyte and refuse
/// everything after it, so a probe of the opening passes and playback dies
/// a minute in. The probe therefore reads past that boundary, and asks for
/// a range as large as the real fetch's.
final class StreamProbeTests: XCTestCase {
    func testALongStreamIsReadPastTheAuthorizationBoundary() {
        let url = URL(string: "https://r1.example.com/videoplayback?itag=141&clen=5000000")!
        let range = InnerTubeService.probeRange(for: url)
        XCTAssertEqual(range.start, 1_048_576)
        XCTAssertGreaterThan(range.end, range.start)
        XCTAssertLessThanOrEqual(range.end, 4_999_999)
    }

    func testAShortStreamIsReadWhole() {
        let url = URL(string: "https://r1.example.com/videoplayback?itag=141&clen=100000")!
        let range = InnerTubeService.probeRange(for: url)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 99_999)
    }

    func testAStreamOfUnknownLengthStillGetsALargeRange() {
        let url = URL(string: "https://r1.example.com/videoplayback?itag=141")!
        let range = InnerTubeService.probeRange(for: url)
        XCTAssertEqual(range.start, 0)
        XCTAssertGreaterThan(range.end, 0)
    }

    func testAndroidVRRangeStaysWithinNarrowWindow() {
        let url = URL(string: "https://r1.example.com/videoplayback?itag=140&c=ANDROID_VR&clen=5000000")!
        let range = InnerTubeService.probeRange(for: url)
        XCTAssertEqual(range.start, 1_048_576)
        XCTAssertEqual(range.end - range.start + 1, 524_288)
    }

    func testChunkedResourceLoaderParsesTotalLengthFromContentRange() {
        let url = URL(string: "https://r1.googlevideo.com/videoplayback?itag=140")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-524287/3482910"]
        )!
        let total = ChunkedResourceLoader.parseTotalLength(
            from: response,
            fallbackDataCount: 524_288,
            windowStart: 0
        )
        XCTAssertEqual(total, 3_482_910)
    }
}
