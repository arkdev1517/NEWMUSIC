import Foundation

struct ResolvedMusicStream: Sendable {
    var url: URL
    var headers: [String: String]
    /// Format facts for the player's "stats for nerds" line. All optional:
    /// a locally downloaded copy resolves without any of them.
    var codec: String? = nil
    var bitrateKbps: Int? = nil
    var sampleRateHz: Int? = nil
    /// The InnerTube client that produced this URL (e.g. "IOS"), shown in
    /// stats and used to dress the media request as the minting client.
    var clientName: String? = nil
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
    /// Stream resolution under a quality ceiling (Android's per-network
    /// `AudioQuality`). The no-ceiling overload above stays for callers that
    /// have no connection context.
    func resolveStream(for track: MusicTrack, quality: AudioQuality) async throws -> ResolvedMusicStream

    /// Every stream that answered for this track, best first.
    ///
    /// The player takes the first and moves on to the next when the one it
    /// was given is refused: a URL that cleared the probe can still be
    /// turned down by the CDN once the player asks it for the bytes it will
    /// really read.
    func resolveStreams(for track: MusicTrack, quality: AudioQuality) async throws -> [ResolvedMusicStream]
    func markStreamRefused(_ stream: ResolvedMusicStream, for track: MusicTrack) async

    // Radio / autoplay: the watch-next queue for `RDAMVM<videoID>`.
    func radio(videoID: String) async throws -> [MusicTrack]

    // Account writes, ported verb-for-verb from `Innertube.kt`.
    func rate(_ status: LikeStatus, videoID: String) async throws
    func setSaved(_ saved: Bool, playlistID: String) async throws
    func setSubscribed(_ subscribed: Bool, channelID: String) async throws
    func createPlaylist(title: String, description: String, videoIDs: [String]) async throws -> String
    func deletePlaylist(_ playlistID: String) async throws
    /// Returns videoID → setVideoID for the entries the response named.
    func addToPlaylist(_ playlistID: String, videoIDs: [String]) async throws -> [String: String]
    func removeFromPlaylist(_ playlistID: String, entries: [PlaylistEntryRef]) async throws
    /// The account's own/saved playlists, for the "Add to playlist" picker.
    func accountPlaylists() async throws -> [MusicItem]
    /// Exact-name artist lookup (Android's `findArtistPageId` safety rule:
    /// a hit counts only when its own title is the name asked for).
    func findArtistPageID(name: String) async throws -> String?

    // Lyrics sources that ride on InnerTube itself.
    /// YouTube Music's Lyrics tab for the exact video (plain, untimed text).
    func youtubeLyrics(videoID: String) async throws -> [LyricLine]?
    /// Timed caption transcript for the exact video.
    func transcriptLyrics(videoID: String) async throws -> [LyricLine]?

    /// The signed-in account's listening history page (`FEmusic_history`).
    func historyTracks() async throws -> [MusicTrack]
}

/// One playlist entry identified the way `browse/edit_playlist` wants it:
/// the entry's set-video-id plus the video id.
struct PlaylistEntryRef: Sendable, Hashable {
    var setVideoID: String
    var videoID: String
}

extension MusicService {
    func markStreamRefused(_ stream: ResolvedMusicStream, for track: MusicTrack) async {}
}

