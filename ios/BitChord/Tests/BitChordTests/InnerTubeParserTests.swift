import XCTest
@testable import BitChord

final class InnerTubeParserTests: XCTestCase {
    func testSearchParserKeepsSongIdentityAndMetadata() {
        let row = searchRow(
            videoID: "video-song-123",
            title: "A real song",
            subtitle: "An artist • Song • 3:42",
            thumbnailWidth: 120,
            thumbnailHeight: 120
        )
        let root: [String: Any] = ["contents": [["musicResponsiveListItemRenderer": row]]]

        let page = InnerTubeParser.parseSearch(root, filter: .songs)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.videoID, "video-song-123")
        XCTAssertEqual(page.items.first?.title, "A real song")
        XCTAssertEqual(page.items.first?.subtitle, "An artist")
        XCTAssertEqual(page.items.first?.kind, .song)
        XCTAssertFalse(page.items.first?.isVideo ?? true)
    }

    func testSearchVideosFilterUsesWideRendererArtwork() {
        let row = searchRow(
            videoID: "video-clip-456",
            title: "Official video",
            subtitle: "An artist • Video • 4:01",
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )
        let root: [String: Any] = ["contents": [["musicResponsiveListItemRenderer": row]]]

        let videoResults = InnerTubeParser.parseSearch(root, filter: .videos)
        let songResults = InnerTubeParser.parseSearch(root, filter: .songs)

        XCTAssertEqual(videoResults.items.map(\.videoID), ["video-clip-456"])
        XCTAssertTrue(videoResults.items.first?.isVideo ?? false)
        XCTAssertTrue(songResults.items.isEmpty)
    }

    func testContinuationTokenIsReadFromRendererEndpoint() {
        let root: [String: Any] = [
            "contents": [
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "opaque-next-token"]]
                ]]
            ]
        ]

        XCTAssertEqual(InnerTubeParser.continuationToken(root), "opaque-next-token")
    }

    func testSuggestionsUseSearchEndpointQueryAndDeduplicate() {
        let root: [String: Any] = [
            "contents": [
                ["searchSuggestionRenderer": [
                    "navigationEndpoint": ["searchEndpoint": ["query": "Artist - Song"]]
                ]],
                ["searchSuggestionRenderer": [
                    "suggestion": ["runs": [["text": "Artist - Song"]]]
                ]]
            ]
        ]

        XCTAssertEqual(InnerTubeParser.parseSuggestions(root), ["Artist - Song"])
    }

    func testTrackDurationAndShareLink() {
        let track = MusicTrack(
            videoID: "abc123",
            title: "Track",
            artist: "Artist",
            durationText: "1:02:03"
        )

        XCTAssertEqual(track.durationSeconds, 3723)
        XCTAssertEqual(track.shareURL?.absoluteString, "https://music.youtube.com/watch?v=abc123")
    }

    private func searchRow(
        videoID: String,
        title: String,
        subtitle: String,
        thumbnailWidth: Int,
        thumbnailHeight: Int
    ) -> [String: Any] {
        [
            "playlistItemData": ["videoId": videoID],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": title]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": subtitle]]]]]
            ],
            "thumbnail": [
                "musicThumbnailRenderer": [
                    "thumbnail": [
                        "thumbnails": [[
                            "url": "https://example.invalid/thumbnail.jpg",
                            "width": thumbnailWidth,
                            "height": thumbnailHeight
                        ]]
                    ]
                ]
            ]
        ]
    }
}
