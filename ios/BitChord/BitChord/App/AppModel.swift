import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var homeShelves: [MusicShelf] = []
    @Published private(set) var homeError: String?
    @Published private(set) var isHomeLoading = false
    @Published private(set) var homeContinuation: String?

    @Published private(set) var exploreSections: [MusicCategorySection] = []
    @Published private(set) var exploreError: String?
    @Published private(set) var isExploreLoading = false

    @Published private(set) var libraryShelves: [MusicShelf] = []
    @Published private(set) var libraryError: String?
    @Published private(set) var isLibraryLoading = false
    @Published private(set) var libraryLoaded = false

    @Published private(set) var searchItems: [MusicItem] = []
    @Published private(set) var localSearchResults: [MusicTrack] = []
    @Published private(set) var searchSuggestions: [String] = []
    @Published private(set) var searchError: String?
    @Published private(set) var isSearchLoading = false
    @Published private(set) var searchContinuation: String?
    @Published var searchQuery = ""
    @Published var searchFilter: SearchFilter = .all
    @Published var searchSource: SearchSource = .youtubeMusic

    @Published private(set) var searchHistory: [MusicSearchHistory] = []
    @Published private(set) var likedTrackIDs: Set<String> = []
    @Published private(set) var isYouTubeSignedIn = false
    @Published var appearance: AppAppearance
    @Published var showingPlayer = false
    @Published var notice: String?
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var queueIndex = 0

    let localAudio: LocalAudioStore
    let playback: PlaybackController
    let listenTogether: ListenTogetherModel

    private let service: any MusicService
    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private var homeRequestID = UUID()
    private var homeGenerationID = UUID()
    private var homeExtrasTask: Task<Void, Never>?
    private var exploreRequestID = UUID()
    private var libraryRequestID = UUID()
    private var searchRequestID = UUID()
    private var streamRequestID = UUID()
    private var streamTask: Task<Void, Never>?
    private var isApplyingPartyState = false
    private var childObservers = Set<AnyCancellable>()

    private let historyKey = "bitchord-search-history-v1"
    private let likedKey = "bitchord-liked-track-ids-v1"
    private let appearanceKey = "bitchord-appearance-v1"

    init(
        service: (any MusicService)? = nil,
        defaults: UserDefaults = .standard,
        credentialStore: (any CredentialStore)? = nil
    ) {
        self.defaults = defaults
        let store = credentialStore ?? KeychainCredentialStore()
        let resolvedService = service ?? InnerTubeService(credentials: store)
        self.credentials = store
        self.service = resolvedService
        localAudio = LocalAudioStore(defaults: defaults)
        playback = PlaybackController()
        listenTogether = ListenTogetherModel(musicService: resolvedService, credentials: store, defaults: defaults)
        appearance = AppAppearance(rawValue: defaults.string(forKey: appearanceKey) ?? "dark") ?? .dark

        localAudio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        listenTogether.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)

        isYouTubeSignedIn = store.string(for: SessionCredential.youtubeCookie) != nil
        if let data = defaults.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([MusicSearchHistory].self, from: data) {
            searchHistory = records
        }
        likedTrackIDs = Set(defaults.stringArray(forKey: likedKey) ?? [])
        playback.onItemEnded = { [weak self] in self?.playNext() }
        playback.onPreviousTrack = { [weak self] in self?.playPrevious() }
        playback.onPlayCommand = { [weak self] in self?.handleRemotePlay() }
        playback.onPauseCommand = { [weak self] in self?.handleRemotePause() }
        playback.onTogglePlaybackCommand = { [weak self] in self?.togglePlayback() }
        playback.onSeekCommand = { [weak self] seconds in self?.seek(to: seconds) }
        listenTogether.onPlaybackUpdate = { [weak self] state, position in
            self?.applyPartyPlayback(state, at: position)
        }
    }

    func loadHome(force: Bool = false) async {
        guard !isHomeLoading || force else { return }
        if !force && !homeShelves.isEmpty { return }
        let requestID = UUID()
        homeRequestID = requestID
        if force || homeShelves.isEmpty {
            homeGenerationID = UUID()
            homeExtrasTask?.cancel()
            homeExtrasTask = nil
        }
        let generationID = homeGenerationID
        isHomeLoading = true
        homeError = nil
        if force {
            homeContinuation = nil
            homeShelves = []
        }
        defer { if homeRequestID == requestID { isHomeLoading = false } }
        do {
            let result = try await service.home()
            guard homeRequestID == requestID else { return }
            homeShelves = result.shelves
            homeContinuation = result.continuation
            homeExtrasTask = Task { [weak self] in await self?.loadHomeExtras(generationID: generationID) }
        } catch {
            guard homeRequestID == requestID else { return }
            homeError = error.localizedDescription
        }
    }

    func loadMoreHome() async {
        guard !isHomeLoading, let token = homeContinuation else { return }
        let requestID = UUID()
        homeRequestID = requestID
        isHomeLoading = true
        defer { if homeRequestID == requestID { isHomeLoading = false } }
        do {
            let result = try await service.moreHome(token)
            guard homeRequestID == requestID else { return }
            homeShelves.append(contentsOf: result.shelves)
            homeContinuation = result.continuation
        } catch {
            guard homeRequestID == requestID else { return }
            homeError = error.localizedDescription
        }
    }

    private func loadHomeExtras(generationID: UUID) async {
        async let recentResult: MusicShelf? = try? await service.homeRecentlyPlayed()
        async let newReleaseResult: [MusicShelf]? = try? await service.homeSupplement("FEmusic_new_releases")
        async let discoveryResult: [MusicShelf]? = try? await service.homeSupplement("FEmusic_explore")
        let (recent, newReleases, discovery) = await (recentResult, newReleaseResult, discoveryResult)
        guard !Task.isCancelled, homeGenerationID == generationID else { return }

        var combined = homeShelves
        if let recent, !combined.contains(where: { $0.id == recent.id }) { combined.insert(recent, at: 0) }
        var knownIDs = Set(combined.map(\.id))
        for shelf in (newReleases ?? []) + (discovery ?? []) where knownIDs.insert(shelf.id).inserted {
            combined.append(shelf)
        }
        homeShelves = combined
    }

    func loadExplore(force: Bool = false) async {
        guard (!isExploreLoading || force), exploreSections.isEmpty || force else { return }
        let requestID = UUID()
        exploreRequestID = requestID
        isExploreLoading = true
        exploreError = nil
        defer { if exploreRequestID == requestID { isExploreLoading = false } }
        do {
            let sections = try await service.explore()
            guard exploreRequestID == requestID else { return }
            exploreSections = sections
        } catch {
            guard exploreRequestID == requestID else { return }
            exploreError = error.localizedDescription
        }
    }

    func loadLibrary(force: Bool = false) async {
        guard !isLibraryLoading, !libraryLoaded || force else { return }
        let requestID = UUID()
        libraryRequestID = requestID
        isLibraryLoading = true
        libraryError = nil
        defer { if libraryRequestID == requestID { isLibraryLoading = false } }
        do {
            let shelves = try await service.library()
            guard libraryRequestID == requestID else { return }
            libraryShelves = shelves
            libraryLoaded = true
        } catch {
            guard libraryRequestID == requestID else { return }
            libraryError = error.localizedDescription
            libraryLoaded = true
        }
    }

    func fetchBrowsePage(_ route: BrowseRoute) async throws -> MusicBrowsePage {
        try await service.browsePage(route)
    }

    func fetchMoreBrowsePage(_ route: BrowseRoute, token: String) async throws -> MusicBrowsePage {
        try await service.moreBrowse(route, token: token)
    }

    func fetchCategoryShelves(_ category: MusicCategory) async throws -> [MusicShelf] {
        try await service.categoryShelves(browseID: category.browseID, params: category.params)
    }

    func submitSearch(_ query: String, filter: SearchFilter? = nil) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            searchItems = []
            searchError = nil
            searchContinuation = nil
            return
        }
        searchQuery = clean
        if let filter { searchFilter = filter }
        recordSearch(clean)
        guard searchSource == .youtubeMusic else {
            searchRequestID = UUID()
            searchItems = []
            localSearchResults = localAudio.tracks.filter { track in
                track.title.localizedCaseInsensitiveContains(clean)
                    || track.artist.localizedCaseInsensitiveContains(clean)
                    || (track.albumName?.localizedCaseInsensitiveContains(clean) ?? false)
            }
            searchSuggestions = []
            searchError = nil
            searchContinuation = nil
            isSearchLoading = false
            return
        }
        localSearchResults = []
        await performSearch(query: clean, filter: searchFilter, replacing: true)
    }

    func setSearchSource(_ source: SearchSource) {
        guard searchSource != source else { return }
        searchSource = source
        searchRequestID = UUID()
        searchItems = []
        localSearchResults = []
        searchSuggestions = []
        searchError = nil
        searchContinuation = nil
        isSearchLoading = false
    }

    func searchForFilter(_ filter: SearchFilter) async {
        guard searchSource == .youtubeMusic else { return }
        searchFilter = filter
        let clean = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        await performSearch(query: clean, filter: filter, replacing: true)
    }

    func loadSearchSuggestions(for query: String) async {
        guard searchSource == .youtubeMusic else {
            searchSuggestions = []
            return
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else {
            searchSuggestions = []
            return
        }
        do {
            let suggestions = try await service.searchSuggestions(clean)
            guard searchSource == .youtubeMusic,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }
            searchSuggestions = suggestions
        } catch {
            // Typeahead is optional; keep the last confirmed result/error visible.
        }
    }

    func loadMoreSearch() async {
        guard searchSource == .youtubeMusic,
              !isSearchLoading,
              let token = searchContinuation else { return }
        let requestID = UUID()
        searchRequestID = requestID
        isSearchLoading = true
        defer { if searchRequestID == requestID { isSearchLoading = false } }
        do {
            let page = try await service.moreSearch(token, filter: searchFilter)
            guard searchRequestID == requestID else { return }
            let existing = Set(searchItems.map(\.id))
            searchItems.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            searchContinuation = page.continuation
        } catch {
            guard searchRequestID == requestID else { return }
            searchError = error.localizedDescription
        }
    }

    func clearSearchResults() {
        searchRequestID = UUID()
        searchItems = []
        localSearchResults = []
        searchSuggestions = []
        searchError = nil
        searchContinuation = nil
        isSearchLoading = false
        searchQuery = ""
    }

    func clearSearchHistory() {
        searchHistory = []
        defaults.removeObject(forKey: historyKey)
    }

    func removeSearchHistory(_ entry: MusicSearchHistory) {
        searchHistory.removeAll { $0.id == entry.id }
        persistSearchHistory()
    }

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        defaults.set(value.rawValue, forKey: appearanceKey)
    }

    func saveYouTubeSession(cookie: String) {
        do {
            try credentials.set(cookie, for: SessionCredential.youtubeCookie)
            isYouTubeSignedIn = true
            libraryLoaded = false
            libraryError = nil
            libraryShelves = []
            notice = "YouTube Music account connected."
        } catch {
            notice = error.localizedDescription
        }
    }

    func signOutYouTube() {
        do {
            try credentials.set(nil, for: SessionCredential.youtubeCookie)
            isYouTubeSignedIn = false
            libraryLoaded = false
            libraryError = nil
            libraryShelves = []
            notice = "Signed out of YouTube Music."
        } catch {
            notice = error.localizedDescription
        }
    }

    func toggleLike(_ track: MusicTrack) {
        let liked = !likedTrackIDs.contains(track.id)
        guard let videoID = track.videoID else {
            notice = "Only YouTube Music tracks can be saved to your account."
            return
        }
        Task {
            do {
                try await service.setLiked(liked, videoID: videoID)
                if liked { likedTrackIDs.insert(track.id) }
                else { likedTrackIDs.remove(track.id) }
                defaults.set(Array(likedTrackIDs), forKey: likedKey)
                notice = liked ? "Added to your YouTube Music likes." : "Removed from your YouTube Music likes."
            } catch { notice = error.localizedDescription }
        }
    }

    func play(_ item: MusicItem, in items: [MusicItem]) {
        guard let track = item.track() else { return }
        play(track, queue: items.compactMap { $0.track() })
    }

    func play(_ track: MusicTrack, queue tracks: [MusicTrack]? = nil) {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        let candidateQueue = tracks?.isEmpty == false ? (tracks ?? [track]) : [track]
        queue = candidateQueue
        queueIndex = candidateQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        showingPlayer = true
        playQueueIndex(queueIndex)
        if listenTogether.isInParty {
            guard track.videoID != nil else {
                notice = "Local audio cannot be added to the shared YouTube Music queue."
                return
            }
            let sharedIndex = candidateQueue.prefix(queueIndex).filter { $0.videoID != nil }.count
            Task { await listenTogether.setSharedTrack(track, queue: candidateQueue, queueIndex: sharedIndex) }
        }
    }

    func togglePlayback() {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        let wasPlaying = playback.isPlaying
        playback.togglePlayback()
        if listenTogether.isInParty && !isApplyingPartyState {
            let action = wasPlaying ? "pause" : "play"
            let position = Int64(max(0, playback.position) * 1000)
            Task { await listenTogether.sendControl(action, fields: ["positionMs": position]) }
        }
    }

    func playNext() {
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("next") }
            return
        }
        guard !queue.isEmpty else { return }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            playQueueIndex(queueIndex)
        } else {
            playback.stop()
            streamTask?.cancel()
            streamTask = nil
        }
    }

    func playPrevious() {
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("previous") }
            return
        }
        guard !queue.isEmpty else { return }
        if playback.position > 3 {
            playback.seek(to: 0)
        } else if queueIndex > 0 {
            queueIndex -= 1
            playQueueIndex(queueIndex)
        } else { playback.seek(to: 0) }
    }

    func seek(to seconds: TimeInterval) {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        playback.seek(to: seconds)
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.shareSeek(positionMs: Int64(max(0, seconds) * 1000)) }
        }
    }

    func dismissNotice() { notice = nil }

    private func handleRemotePlay() {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        playback.play()
        if listenTogether.isInParty && !isApplyingPartyState {
            let position = Int64(max(0, playback.position) * 1000)
            Task { await listenTogether.sendControl("play", fields: ["positionMs": position]) }
        }
    }

    private func handleRemotePause() {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        let position = Int64(max(0, playback.position) * 1000)
        playback.pause()
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("pause", fields: ["positionMs": position]) }
        }
    }

    private func performSearch(query: String, filter: SearchFilter, replacing: Bool) async {
        guard searchSource == .youtubeMusic,
              !isSearchLoading || replacing else { return }
        let requestID = UUID()
        searchRequestID = requestID
        isSearchLoading = true
        searchError = nil
        if replacing {
            searchItems = []
            searchContinuation = nil
        }
        defer { if searchRequestID == requestID { isSearchLoading = false } }
        do {
            let page = try await service.searchPage(query, filter: filter)
            guard searchRequestID == requestID else { return }
            searchItems = page.items
            searchContinuation = page.continuation
            searchSuggestions = []
        } catch {
            guard searchRequestID == requestID else { return }
            searchError = error.localizedDescription
        }
    }

    private func recordSearch(_ query: String) {
        searchHistory.removeAll { $0.id == query.lowercased() }
        searchHistory.insert(MusicSearchHistory(query: query, date: Date()), at: 0)
        searchHistory = Array(searchHistory.prefix(30))
        persistSearchHistory()
    }

    private func persistSearchHistory() {
        guard let data = try? JSONEncoder().encode(searchHistory) else { return }
        defaults.set(data, forKey: historyKey)
    }

    private func applyPartyPlayback(_ state: PartyPlayback, at position: TimeInterval) {
        guard listenTogether.isInParty, let sharedTrack = state.track else { return }
        isApplyingPartyState = true
        defer { isApplyingPartyState = false }

        let track = MusicTrack(
            videoID: sharedTrack.videoId,
            title: sharedTrack.title.isEmpty ? "YouTube Music track" : sharedTrack.title,
            artist: sharedTrack.artist.isEmpty ? "Unknown artist" : sharedTrack.artist,
            artworkURL: sharedTrack.thumbnailUrl,
            durationText: durationLabel(sharedTrack.durationMs),
            albumName: nil,
            localFileName: nil
        )
        var sharedQueue = listenTogether.queue.items.map { item in
            MusicTrack(
                videoID: item.videoId,
                title: item.title.isEmpty ? "YouTube Music track" : item.title,
                artist: item.artist.isEmpty ? "Unknown artist" : item.artist,
                artworkURL: item.thumbnailUrl,
                durationText: durationLabel(item.durationMs),
                albumName: nil,
                localFileName: nil
            )
        }
        if sharedQueue.isEmpty { sharedQueue = [track] }
        var newIndex = listenTogether.queue.index
        if !sharedQueue.indices.contains(newIndex) || sharedQueue[newIndex].videoID != track.videoID {
            newIndex = sharedQueue.firstIndex(where: { $0.videoID == track.videoID }) ?? -1
        }
        if newIndex < 0 {
            sharedQueue.insert(track, at: 0)
            newIndex = 0
        }
        queue = sharedQueue
        queueIndex = newIndex

        if playback.currentTrack?.videoID != track.videoID {
            playQueueIndex(newIndex, autoplay: state.isPlaying, startAt: position)
        } else {
            playback.synchronize(isPlaying: state.isPlaying, position: position)
        }
    }

    private func durationLabel(_ milliseconds: Int64?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let seconds = milliseconds / 1000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainder))" }
        return "\(minutes):\(String(format: "%02d", remainder))"
    }

    private func playQueueIndex(_ index: Int, autoplay: Bool = true, startAt: TimeInterval = 0) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        streamRequestID = UUID()
        let requestID = streamRequestID
        streamTask?.cancel()
        playback.beginLoading(track)
        localAudio.recordRecent(track)

        if track.localFileName != nil {
            do {
                let url = try localAudio.localURL(for: track)
                playback.load(url: url, track: track, autoplay: autoplay, startAt: startAt)
            } catch { playback.failLoading(error.localizedDescription) }
            return
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.service.resolveStream(for: track)
                guard self.streamRequestID == requestID else { return }
                let sharedState = self.listenTogether.isInParty ? self.listenTogether.party?.playback : nil
                let stateMatchesTrack = sharedState?.track?.videoId == track.videoID
                let finalAutoplay = stateMatchesTrack ? (sharedState?.isPlaying ?? autoplay) : autoplay
                let finalPosition = stateMatchesTrack ? (self.listenTogether.partyPositionSeconds ?? startAt) : startAt
                self.playback.load(
                    url: resolved.url,
                    headers: resolved.headers,
                    track: track,
                    autoplay: finalAutoplay,
                    startAt: finalPosition
                )
            } catch {
                guard self.streamRequestID == requestID else { return }
                self.playback.failLoading(error.localizedDescription)
            }
        }
    }
}
