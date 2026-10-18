import Foundation

struct ResolvedMusicStream: Sendable {
    var url: URL
    var headers: [String: String]
}

/// Test seam for the music catalogue, account mutations and stream resolver.
/// Implementations are actors so URLSession work never blocks SwiftUI.
protocol MusicService: Sendable {
    func home() async throws -> MusicFeed
    func homeRecentlyPlayed() async throws -> MusicShelf?
    func homeSupplement(_ browseID: String) async throws -> [MusicShelf]
    func moreHome(_ token: String) async throws -> MusicFeed
    func explore() async throws -> [MusicCategorySection]
    func categoryShelves(browseID: String, params: String?) async throws -> [MusicShelf]
    func searchPage(_ query: String, filter: SearchFilter) async throws -> MusicSearchPage
    func moreSearch(_ token: String, filter: SearchFilter) async throws -> MusicSearchPage
    func searchSuggestions(_ query: String) async throws -> [String]
    func browsePage(_ route: BrowseRoute) async throws -> MusicBrowsePage
    func moreBrowse(_ route: BrowseRoute, token: String) async throws -> MusicBrowsePage
    func library() async throws -> [MusicShelf]
    func account() async throws -> MusicAccount
    func setLiked(_ liked: Bool, videoID: String) async throws
    func resolveStream(for track: MusicTrack) async throws -> ResolvedMusicStream
}
