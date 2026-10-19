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
    @Published private(set) var dislikedTrackIDs: Set<String> = []
    @Published private(set) var savedPlaylistIDs: Set<String> = []
    @Published private(set) var subscribedChannelIDs: Set<String> = []
    @Published private(set) var isYouTubeSignedIn = false
    @Published private(set) var accountProfile: MusicAccount?
    @Published var appearance: AppAppearance
    @Published var showingPlayer = false
    @Published var notice: String?
    /// When set, the root presents the "Add to playlist" picker for this
    /// track (context menus anywhere can raise it without owning a sheet).
    @Published var playlistPickerTrack: MusicTrack?
    /// When set, the root presents this browse page in a sheet — how "Go to
    /// artist / album" from any row or menu reaches a page.
    @Published var presentedRoute: BrowseRoute?
    /// The queue in effective play order plus the current position in it,
    /// mirrored from `engine` for the views.
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var queueIndex = 0
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var currentLyrics: TrackLyrics?
    @Published private(set) var isLyricsLoading = false
    @Published private(set) var currentStreamInfo: ResolvedMusicStream?

    let localAudio: LocalAudioStore
    let playback: PlaybackController
    let listenTogether: ListenTogetherModel
    let settings: AppSettings
    let network: NetworkMonitor
    let downloads: DownloadManager
    let playlists: PlaylistStore
    let recorder: ListeningRecorder
    let scrobbler: ScrobbleManager
    let sleepTimer: SleepTimer

    private let service: any MusicService
    private let lyricsService: LyricsService
    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private var engine = QueueEngine()
    private var lyricsTrackID: String?
    private var lyricsTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var secondsSinceSessionSave = 0
    private var homeRequestID = UUID()
    private var homeGenerationID = UUID()
    private var homeExtrasTask: Task<Void, Never>?
    private var exploreRequestID = UUID()
    private var libraryRequestID = UUID()
    private var searchRequestID = UUID()
    private var streamRequestID = UUID()
    private var streamTask: Task<Void, Never>?
    /// The stream being fed to the player and the ones behind it, for a
    /// track whose first stream was refused.
    private var streamAttempt: StreamAttempt?
    private var isApplyingPartyState = false
    private var childObservers = Set<AnyCancellable>()

    private let historyKey = "bitchord-search-history-v1"
    private let likedKey = "bitchord-liked-track-ids-v1"
    private let dislikedKey = "bitchord-disliked-track-ids-v1"
    private let savedPlaylistsKey = "bitchord-saved-playlist-ids-v1"
    private let subscribedKey = "bitchord-subscribed-channel-ids-v1"
    private let appearanceKey = "bitchord-appearance-v1"
    private let sessionKey = "bitchord-last-session-v1"

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
        lyricsService = LyricsService(service: resolvedService)
        localAudio = LocalAudioStore(defaults: defaults)
        playback = PlaybackController()
        listenTogether = ListenTogetherModel(musicService: resolvedService, credentials: store, defaults: defaults)
        let appSettings = AppSettings(defaults: defaults)
        settings = appSettings
        network = NetworkMonitor()
        downloads = DownloadManager(service: resolvedService, defaults: defaults)
        playlists = PlaylistStore()
        recorder = ListeningRecorder()
        scrobbler = ScrobbleManager(settings: appSettings, credentials: store)
        sleepTimer = SleepTimer()
        appearance = AppAppearance(rawValue: defaults.string(forKey: appearanceKey) ?? "dark") ?? .dark

        engine.shuffleEnabled = appSettings.shuffleEnabled
        engine.repeatMode = appSettings.repeatMode
        shuffleEnabled = appSettings.shuffleEnabled
        repeatMode = appSettings.repeatMode

        localAudio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        listenTogether.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        downloads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        playlists.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        scrobbler.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        sleepTimer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)

        isYouTubeSignedIn = store.string(for: SessionCredential.youtubeCookie) != nil
        if let data = defaults.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([MusicSearchHistory].self, from: data) {
            searchHistory = records
        }
        likedTrackIDs = Set(defaults.stringArray(forKey: likedKey) ?? [])
        dislikedTrackIDs = Set(defaults.stringArray(forKey: dislikedKey) ?? [])
        savedPlaylistIDs = Set(defaults.stringArray(forKey: savedPlaylistsKey) ?? [])
        subscribedChannelIDs = Set(defaults.stringArray(forKey: subscribedKey) ?? [])
        playback.setRate(Float(appSettings.playbackSpeed))
        playback.onItemEnded = { [weak self] in self?.handleTrackEnded() }
        playback.onNextTrackCommand = { [weak self] in self?.playNext() }
        playback.onPreviousTrack = { [weak self] in self?.playPrevious() }
        playback.onPlayCommand = { [weak self] in self?.handleRemotePlay() }
        playback.onPauseCommand = { [weak self] in self?.handleRemotePause() }
        playback.onTogglePlaybackCommand = { [weak self] in self?.togglePlayback() }
        playback.onSeekCommand = { [weak self] seconds in self?.seek(to: seconds) }
        playback.onLoadFailure = { [weak self] error in self?.handleStreamFailure(error) }
        listenTogether.onPlaybackUpdate = { [weak self] state, position in
            self?.applyPartyPlayback(state, at: position)
        }

        // Position-driven work: listening history, scrobble timing, the
        // crossfade ramp, and periodic session persistence. The player
        // reports every 0.35s while a track is loaded.
        playback.$position
            .sink { [weak self] _ in self?.handlePositionTick() }
            .store(in: &childObservers)
        // The sleep deadline must fire even while position is not moving.
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkSleepTimer() }
            .store(in: &childObservers)

        restoreSession()
        if isYouTubeSignedIn {
            Task { await self.refreshAccountProfile() }
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
            accountProfile = nil
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
                try await service.rate(liked ? .like : .indifferent, videoID: videoID)
                if liked {
                    likedTrackIDs.insert(track.id)
                    dislikedTrackIDs.remove(track.id)
                } else {
                    likedTrackIDs.remove(track.id)
                }
                persistRatingSets()
                notice = liked ? "Added to Liked Music." : "Removed from Liked Music."
            } catch { notice = error.localizedDescription }
        }
    }

    func toggleDislike(_ track: MusicTrack) {
        let disliked = !dislikedTrackIDs.contains(track.id)
        guard let videoID = track.videoID else {
            notice = "Only YouTube Music tracks can be rated on your account."
            return
        }
        Task {
            do {
                try await service.rate(disliked ? .dislike : .indifferent, videoID: videoID)
                if disliked {
                    dislikedTrackIDs.insert(track.id)
                    likedTrackIDs.remove(track.id)
                } else {
                    dislikedTrackIDs.remove(track.id)
                }
                persistRatingSets()
                if disliked, playback.currentTrack?.id == track.id {
                    // A disliked playing track does not get to finish.
                    playNext()
                }
            } catch { notice = error.localizedDescription }
        }
    }

    /// Save/remove an album or playlist in the account library
    /// (`ratePlaylist` on Android — a saved release *is* a liked one).
    func toggleSaved(playlistID: String) {
        let saved = !savedPlaylistIDs.contains(playlistID)
        Task {
            do {
                try await service.setSaved(saved, playlistID: playlistID)
                if saved { savedPlaylistIDs.insert(playlistID) } else { savedPlaylistIDs.remove(playlistID) }
                defaults.set(Array(savedPlaylistIDs), forKey: savedPlaylistsKey)
                notice = saved ? "Saved to your library." : "Removed from your library."
            } catch { notice = error.localizedDescription }
        }
    }

    func toggleSubscription(channelID: String) {
        let subscribed = !subscribedChannelIDs.contains(channelID)
        Task {
            do {
                try await service.setSubscribed(subscribed, channelID: channelID)
                if subscribed { subscribedChannelIDs.insert(channelID) } else { subscribedChannelIDs.remove(channelID) }
                defaults.set(Array(subscribedChannelIDs), forKey: subscribedKey)
                notice = subscribed ? "Subscribed." : "Unsubscribed."
            } catch { notice = error.localizedDescription }
        }
    }

    private func persistRatingSets() {
        defaults.set(Array(likedTrackIDs), forKey: likedKey)
        defaults.set(Array(dislikedTrackIDs), forKey: dislikedKey)
    }

    func refreshAccountProfile() async {
        guard isYouTubeSignedIn else {
            accountProfile = nil
            return
        }
        accountProfile = try? await service.account()
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
        let startIndex = candidateQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        engine.setQueue(candidateQueue, startIndex: startIndex)
        syncQueue()
        showingPlayer = true
        playCurrent()
        shareQueueWithPartyIfNeeded(current: track)
    }

    func togglePlayback() {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        // A restored session has a track on display but no loaded stream;
        // the first play press is what resolves it.
        if playback.currentTrack != nil, !playback.hasLoadedItem, !playback.isLoading {
            playCurrent(autoplay: true, startAt: playback.position)
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

    /// Manual skip forward (UI button or lock-screen next command).
    func playNext() {
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("next") }
            return
        }
        guard !engine.isEmpty else { return }
        switch engine.advance(manual: true) {
        case .playTrack:
            syncQueue()
            playCurrent()
        case .restartCurrent:
            playback.seek(to: 0)
            playback.play()
        case .finished:
            finishQueueOrAutoplay(manual: true)
        }
    }

    func playPrevious() {
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("previous") }
            return
        }
        guard !engine.isEmpty else { return }
        if playback.position > 3 {
            playback.seek(to: 0)
        } else if engine.goPrevious() {
            syncQueue()
            playCurrent()
        } else { playback.seek(to: 0) }
    }

    /// The current item reached its end on its own: repeat-one, sleep
    /// timer and autoplay all get their say here, in that order of force.
    private func handleTrackEnded() {
        if sleepTimer.afterTrack {
            sleepTimer.cancel()
            playback.pause()
            recorder.stop()
            scrobbler.stopped()
            notice = "Sleep timer stopped playback."
            saveSession()
            return
        }
        if listenTogether.isInParty && !isApplyingPartyState {
            Task { await listenTogether.sendControl("next") }
            return
        }
        switch engine.advance(manual: false) {
        case .restartCurrent:
            if let track = engine.currentTrack {
                recorder.begin(track, duration: playback.duration)
                scrobbler.trackStarted(track, duration: playback.duration)
            }
            playback.seek(to: 0)
            playback.play()
        case .playTrack:
            syncQueue()
            playCurrent()
        case .finished:
            finishQueueOrAutoplay(manual: false)
        }
    }

    private func finishQueueOrAutoplay(manual: Bool) {
        let seed = engine.currentTrack?.videoID ?? playback.currentTrack?.videoID
        guard settings.autoplay, !listenTogether.isInParty, let seed else {
            stopPlayback()
            return
        }
        autoplayTask?.cancel()
        autoplayTask = Task { [weak self] in
            guard let self else { return }
            if await self.topUpWithRadio(seedVideoID: seed),
               self.engine.advance(manual: manual) == .playTrack {
                self.syncQueue()
                self.playCurrent()
            } else {
                self.stopPlayback()
            }
        }
    }

    private func stopPlayback() {
        recorder.stop()
        scrobbler.stopped()
        playback.stop()
        currentLyrics = nil
        currentStreamInfo = nil
        streamTask?.cancel()
        streamTask = nil
        clearSession()
    }

    /// Appends a radio continuation seeded by `seedVideoID` (skipping
    /// anything already queued). True when at least one fresh track landed.
    @discardableResult
    private func topUpWithRadio(seedVideoID: String) async -> Bool {
        guard let related = try? await service.radio(videoID: seedVideoID) else { return false }
        let known = Set(engine.tracks.map(\.id))
        let fresh = related.filter { !known.contains($0.id) && $0.videoID != seedVideoID }
        guard !fresh.isEmpty else { return false }
        engine.appendToQueue(fresh)
        syncQueue()
        saveSession()
        return true
    }

    /// "Start radio" from a song's actions: play the seed now, then fill
    /// the queue behind it with its watch-next relatives.
    func startRadio(_ track: MusicTrack) {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        guard let videoID = track.videoID else {
            notice = "Radio needs a YouTube Music track to start from."
            return
        }
        engine.setQueue([track], startIndex: 0)
        syncQueue()
        showingPlayer = true
        playCurrent()
        shareQueueWithPartyIfNeeded(current: track)
        Task { [weak self] in
            guard let self else { return }
            if await self.topUpWithRadio(seedVideoID: videoID) {
                self.notice = "Radio started · \(track.title)"
            }
        }
    }

    /// The detail pages' Shuffle button: this collection, in shuffled
    /// order, without touching the saved shuffle preference.
    func playShuffled(_ tracks: [MusicTrack]) {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        guard !tracks.isEmpty else { return }
        let wasShuffle = engine.shuffleEnabled
        engine.shuffleEnabled = true
        engine.setQueue(tracks, startIndex: Int.random(in: tracks.indices))
        engine.shuffleEnabled = wasShuffle
        syncQueue()
        showingPlayer = true
        playCurrent()
        if let current = engine.currentTrack { shareQueueWithPartyIfNeeded(current: current) }
    }

    func toggleShuffle() {
        engine.setShuffle(!engine.shuffleEnabled)
        settings.shuffleEnabled = engine.shuffleEnabled
        shuffleEnabled = engine.shuffleEnabled
        syncQueue()
        saveSession()
    }

    func cycleRepeat() {
        engine.repeatMode = engine.repeatMode.next
        settings.repeatMode = engine.repeatMode
        repeatMode = engine.repeatMode
    }

    func setPlaybackSpeed(_ speed: Double) {
        let clamped = min(max(speed, 0.5), 2.0)
        settings.playbackSpeed = clamped
        playback.setRate(Float(clamped))
    }

    // MARK: Queue editing

    func playTrackNext(_ track: MusicTrack) {
        engine.insertNext(track)
        syncQueue()
        saveSession()
        notice = "Song will play next."
    }

    func addToQueue(_ track: MusicTrack) {
        engine.appendToQueue(track)
        syncQueue()
        saveSession()
        notice = "Added to queue."
    }

    func jumpToQueueItem(at index: Int) {
        if listenTogether.isInParty && !listenTogether.mayControl {
            notice = "Only the host can control playback in this party."
            return
        }
        guard engine.jump(toEffectiveIndex: index) else { return }
        syncQueue()
        playCurrent()
        if let current = engine.currentTrack { shareQueueWithPartyIfNeeded(current: current) }
    }

    func removeFromQueue(at index: Int) {
        let wasCurrent = engine.remove(atEffectiveIndex: index)
        syncQueue()
        if engine.isEmpty {
            stopPlayback()
            return
        }
        if wasCurrent { playCurrent() }
        saveSession()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        engine.move(fromEffectiveIndex: source, toEffectiveIndex: destination)
        syncQueue()
        saveSession()
    }

    private func syncQueue() {
        queue = engine.effectiveQueue
        queueIndex = engine.effectiveIndex
    }

    private func shareQueueWithPartyIfNeeded(current: MusicTrack) {
        guard listenTogether.isInParty else { return }
        guard current.videoID != nil else {
            notice = "Local audio cannot be added to the shared YouTube Music queue."
            return
        }
        let effective = engine.effectiveQueue
        let sharedIndex = effective.prefix(engine.effectiveIndex).filter { $0.videoID != nil }.count
        Task { await listenTogether.setSharedTrack(current, queue: effective, queueIndex: sharedIndex) }
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
        if playback.currentTrack != nil, !playback.hasLoadedItem, !playback.isLoading {
            playCurrent(autoplay: true, startAt: playback.position)
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
        engine.setQueuePreservingOrder(sharedQueue, startIndex: newIndex)
        syncQueue()

        if playback.currentTrack?.videoID != track.videoID {
            playCurrent(autoplay: state.isPlaying, startAt: position)
        } else {
            playback.synchronize(isPlaying: state.isPlaying, position: position)
        }
    }

    /// The stream being played and the ones behind it, for a track whose
    /// first stream the player refused.
    private struct StreamAttempt {
        var track: MusicTrack
        var autoplay: Bool
        var startAt: TimeInterval
        var candidates: [ResolvedMusicStream]
        var index: Int
        var reResolveCount: Int = 0
        var requestID: UUID
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

    /// Plays whatever the engine currently points at. Resolution order is
    /// the offline-first one Android uses: a downloaded copy, then an
    /// imported file, then a resolved stream under the quality ceiling for
    /// the current connection.
    private func playCurrent(autoplay: Bool = true, startAt: TimeInterval = 0) {
        guard let track = engine.currentTrack else { return }
        streamRequestID = UUID()
        let requestID = streamRequestID
        streamTask?.cancel()
        streamAttempt = nil
        playback.beginLoading(track)
        localAudio.recordRecent(track)
        currentStreamInfo = nil
        recorder.begin(track, duration: playback.duration)
        scrobbler.trackStarted(track, duration: track.durationSeconds ?? 0)
        loadLyrics(for: track)
        saveSession()

        if let localURL = localFileURL(for: track) {
            playback.load(url: localURL, track: track, autoplay: autoplay, startAt: startAt)
            return
        }
        if track.localFileName != nil {
            playback.failLoading("This imported file is no longer available.")
            return
        }

        let quality = settings.effectiveQuality(metered: network.isMetered)
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.service.resolveStreams(for: track, quality: quality)
                guard self.streamRequestID == requestID else { return }
                let sharedState = self.listenTogether.isInParty ? self.listenTogether.party?.playback : nil
                let stateMatchesTrack = sharedState?.track?.videoId == track.videoID
                let finalAutoplay = stateMatchesTrack ? (sharedState?.isPlaying ?? autoplay) : autoplay
                let finalPosition = stateMatchesTrack ? (self.listenTogether.partyPositionSeconds ?? startAt) : startAt
                self.streamAttempt = StreamAttempt(
                    track: track,
                    autoplay: finalAutoplay,
                    startAt: finalPosition,
                    candidates: resolved,
                    index: 0,
                    requestID: requestID
                )
                self.loadNextCandidate()
            } catch {
                guard self.streamRequestID == requestID else { return }
                self.playback.failLoading(error.localizedDescription)
            }
        }
    }

    /// The next stream the resolver found for the track being played.
    ///
    /// The first one can be refused by the CDN even though it cleared the
    /// probe, so the ones behind it are tried in turn before the track is
    /// given up on.
    private func loadNextCandidate(afterFailure error: Error? = nil) {
        guard var attempt = streamAttempt else {
            playback.failLoading(PlaybackController.message(for: error))
            return
        }
        // A failure from a track that is no longer the one being played.
        guard streamRequestID == attempt.requestID else { return }
        if attempt.index >= attempt.candidates.count {
            if attempt.reResolveCount < 2, let failedStream = attempt.candidates.last {
                let nextReResolveCount = attempt.reResolveCount + 1
                let requestID = attempt.requestID
                let track = attempt.track
                let autoplay = attempt.autoplay
                let startAt = attempt.startAt
                let quality = settings.effectiveQuality(metered: network.isMetered)
                streamAttempt = nil
                streamTask?.cancel()
                streamTask = Task { [weak self] in
                    guard let self else { return }
                    await self.service.markStreamRefused(failedStream, for: track)
                    do {
                        let resolved = try await self.service.resolveStreams(for: track, quality: quality)
                        guard self.streamRequestID == requestID else { return }
                        self.streamAttempt = StreamAttempt(
                            track: track,
                            autoplay: autoplay,
                            startAt: startAt,
                            candidates: resolved,
                            index: 0,
                            reResolveCount: nextReResolveCount,
                            requestID: requestID
                        )
                        self.loadNextCandidate(afterFailure: error)
                    } catch {
                        guard self.streamRequestID == requestID else { return }
                        self.playback.failLoading(PlaybackController.message(for: error))
                    }
                }
                return
            }
            streamAttempt = nil
            playback.failLoading(PlaybackController.message(for: error))
            return
        }
        let candidate = attempt.candidates[attempt.index]
        attempt.index += 1
        streamAttempt = attempt
        currentStreamInfo = candidate
        playback.load(
            url: candidate.url,
            headers: candidate.headers,
            track: attempt.track,
            autoplay: attempt.autoplay,
            startAt: attempt.startAt
        )
    }

    /// The player would not load the stream it was given: try the next one.
    private func handleStreamFailure(_ error: Error?) {
        guard let attempt = streamAttempt, streamRequestID == attempt.requestID else { return }
        loadNextCandidate(afterFailure: error)
    }

    /// The on-device copy of a track, if one exists: a finished download
    /// first, then an imported file.
    func localFileURL(for track: MusicTrack) -> URL? {
        if let downloaded = downloads.localURL(for: track) { return downloaded }
        if track.localFileName != nil { return try? localAudio.localURL(for: track) }
        return nil
    }

    private func loadLyrics(for track: MusicTrack) {
        lyricsTask?.cancel()
        lyricsTrackID = track.id
        currentLyrics = nil
        isLyricsLoading = true
        let localURL = localFileURL(for: track)
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.lyrics(for: track, localFileURL: localURL)
            guard self.lyricsTrackID == track.id else { return }
            self.currentLyrics = result
            self.isLyricsLoading = false
        }
    }

    // MARK: Position-driven work

    private func handlePositionTick() {
        let isPlaying = playback.isPlaying
        recorder.tick(isPlaying: isPlaying)
        scrobbler.tick(isPlaying: isPlaying)
        if playback.duration > 0 {
            recorder.updateDuration(playback.duration)
        }
        updateCrossfadeRamp()
        if isPlaying {
            secondsSinceSessionSave += 1
            if secondsSinceSessionSave >= 30 {
                secondsSinceSessionSave = 0
                saveSession()
            }
        }
    }

    private func updateCrossfadeRamp() {
        let fade = settings.crossfadeSeconds
        guard fade > 0, playback.duration > 0, playback.hasLoadedItem else { return }
        let remaining = playback.duration - playback.position
        if playback.isPlaying, remaining < Double(fade), engine.hasNext || settings.autoplay {
            playback.setVolume(Float(max(0, remaining) / Double(fade)))
        } else {
            playback.setVolume(1)
        }
    }

    private func checkSleepTimer() {
        guard sleepTimer.isExpired else { return }
        sleepTimer.cancel()
        playback.pause()
        saveSession()
        notice = "Sleep timer stopped playback."
    }

    // MARK: Session persistence (LastPlayed)

    private struct SavedSession: Codable {
        var tracks: [MusicTrack]
        var index: Int
        var position: TimeInterval
    }

    private func saveSession() {
        guard !engine.isEmpty else { return }
        let session = SavedSession(
            tracks: engine.effectiveQueue,
            index: engine.effectiveIndex,
            position: playback.position
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    private func clearSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    private func restoreSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              !saved.tracks.isEmpty else { return }
        engine.setQueuePreservingOrder(saved.tracks, startIndex: saved.index)
        syncQueue()
        if let track = engine.currentTrack {
            playback.restoreSession(track: track, position: saved.position)
            loadLyrics(for: track)
        }
    }

    // MARK: Downloads

    func downloadTrack(_ track: MusicTrack) {
        guard track.videoID != nil else {
            notice = "Only YouTube Music tracks can be downloaded."
            return
        }
        guard settings.downloadsAllowed(metered: network.isMetered) else {
            notice = "Downloads are set to Wi-Fi only. Connect to Wi-Fi, or allow mobile data in Settings."
            return
        }
        let quality = settings.downloadQuality
        Task {
            await downloads.download(track, quality: quality)
            if let failure = downloads.failures[track.id] { notice = failure }
            else if downloads.isDownloaded(track) { notice = "Saved to Downloads." }
        }
    }

    func downloadTracks(_ tracks: [MusicTrack]) {
        guard settings.downloadsAllowed(metered: network.isMetered) else {
            notice = "Downloads are set to Wi-Fi only. Connect to Wi-Fi, or allow mobile data in Settings."
            return
        }
        let pending = tracks.filter { $0.videoID != nil && !downloads.isDownloaded($0) && !downloads.isDownloading($0) }
        guard !pending.isEmpty else {
            notice = "Everything here is already downloaded."
            return
        }
        notice = pending.count == 1 ? "Download started." : "Downloading \(pending.count) songs…"
        let quality = settings.downloadQuality
        Task {
            for track in pending {
                await downloads.download(track, quality: quality)
            }
        }
    }

    func deleteDownload(_ track: MusicTrack) {
        downloads.delete(track)
        notice = "Download deleted."
    }

    // MARK: Playlists (account)

    func fetchAccountPlaylists() async -> [MusicItem] {
        (try? await service.accountPlaylists()) ?? []
    }

    func createAccountPlaylist(title: String, firstTrack: MusicTrack?) {
        Task {
            do {
                let ids = firstTrack?.videoID.map { [$0] } ?? []
                _ = try await service.createPlaylist(title: title, description: "", videoIDs: ids)
                notice = "Playlist created on YouTube Music."
                libraryLoaded = false
            } catch { notice = error.localizedDescription }
        }
    }

    func addTrackToAccountPlaylist(_ track: MusicTrack, playlistID: String) {
        guard let videoID = track.videoID else {
            notice = "Only YouTube Music tracks can be added to an account playlist."
            return
        }
        Task {
            do {
                _ = try await service.addToPlaylist(playlistID, videoIDs: [videoID])
                notice = "Added to playlist."
            } catch { notice = error.localizedDescription }
        }
    }

    func removeTrackFromAccountPlaylist(_ track: MusicTrack, playlistID: String) {
        guard let videoID = track.videoID, let setVideoID = track.setVideoID else {
            notice = "Reopen the playlist before removing tracks, so every entry is identified."
            return
        }
        Task {
            do {
                try await service.removeFromPlaylist(
                    playlistID,
                    entries: [PlaylistEntryRef(setVideoID: setVideoID, videoID: videoID)]
                )
                notice = "Removed from playlist."
            } catch { notice = error.localizedDescription }
        }
    }

    func deleteAccountPlaylist(_ playlistID: String) {
        Task {
            do {
                try await service.deletePlaylist(playlistID)
                notice = "Playlist deleted."
                libraryLoaded = false
            } catch { notice = error.localizedDescription }
        }
    }

    /// The browse route for a track's artist: the byline's own link when the
    /// row carried one, else Android's exact-name artist search.
    func artistRoute(for track: MusicTrack) async -> BrowseRoute? {
        if let browseID = track.artistBrowseID {
            return BrowseRoute(browseID: browseID, title: track.artist, kind: .artist)
        }
        let name = ScrobbleManager.primaryArtist(track.artist)
        guard let found = try? await service.findArtistPageID(name: name) else { return nil }
        return BrowseRoute(browseID: found, title: name, kind: .artist)
    }

    func fetchAccountHistory() async throws -> [MusicTrack] {
        try await service.historyTracks()
    }

    // MARK: Menu-driven navigation and collection playback

    func presentArtist(for track: MusicTrack) {
        if let browseID = track.artistBrowseID {
            presentedRoute = BrowseRoute(browseID: browseID, title: track.artist, kind: .artist)
            return
        }
        Task {
            if let route = await artistRoute(for: track) {
                presentedRoute = route
            } else {
                notice = "No artist page found for \(track.artist)."
            }
        }
    }

    func presentAlbum(for track: MusicTrack) {
        guard let browseID = track.albumBrowseID else {
            notice = "This track doesn't name its album page."
            return
        }
        presentedRoute = BrowseRoute(
            browseID: browseID,
            title: track.albumName ?? "Album",
            artworkURL: track.artworkURL,
            kind: .album
        )
    }

    /// The browse-card actions (Android's `BrowseActionsSheet`): fetch the
    /// collection's tracks and play them, in order or shuffled.
    func playCollection(_ item: MusicItem, shuffled: Bool) {
        guard let route = item.browseRoute() else { return }
        Task {
            do {
                let page = try await service.browsePage(route)
                guard let first = page.tracks.first else {
                    notice = "Nothing playable in \(item.title)."
                    return
                }
                if shuffled {
                    playShuffled(page.tracks)
                } else {
                    play(first, queue: page.tracks)
                }
            } catch { notice = error.localizedDescription }
        }
    }

    // MARK: Backup

    func makeBackup() throws -> Data {
        try BitChordBackup(
            formatVersion: BitChordBackup.currentFormatVersion,
            exportedAt: Date(),
            settings: settings.exportValues(),
            playlists: playlists.playlists,
            listeningEvents: recorder.events,
            searchHistory: searchHistory
        ).encoded()
    }

    func restoreBackup(from data: Data) throws {
        let backup = try BitChordBackup.decoded(from: data)
        settings.importValues(backup.settings)
        engine.setShuffle(settings.shuffleEnabled)
        engine.repeatMode = settings.repeatMode
        shuffleEnabled = settings.shuffleEnabled
        repeatMode = settings.repeatMode
        playback.setRate(Float(settings.playbackSpeed))
        playlists.importPlaylists(backup.playlists)
        recorder.importEvents(backup.listeningEvents)
        searchHistory = backup.searchHistory
        persistSearchHistory()
        syncQueue()
        notice = "Backup restored."
    }
}
