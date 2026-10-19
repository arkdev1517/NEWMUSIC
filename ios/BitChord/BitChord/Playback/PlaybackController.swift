import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTrack: MusicTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    /// Playback speed (Android offers 0.5×–2.0×). Setting AVPlayer's rate is
    /// also how playback starts, so `play()` goes through `desiredRate`.
    @Published private(set) var rate: Float = 1.0
    private var desiredRate: Float = 1.0

    var onItemEnded: (() -> Void)?
    var onNextTrackCommand: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onPlayCommand: (() -> Void)?
    var onPauseCommand: (() -> Void)?
    var onTogglePlaybackCommand: (() -> Void)?
    var onSeekCommand: ((TimeInterval) -> Void)?
    /// Called when an item will not load, so the caller can try another
    /// stream for the same track before giving up on it.
    var onLoadFailure: ((Error?) -> Void)?

    private let player = AVPlayer()
    private var resourceLoader: ChunkedResourceLoader?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var remoteTargets: [Any] = []
    private var artworkTask: Task<Void, Never>?
    private var loadingArtworkForID: String?
    private var autoplayWhenReady = true
    private var initialPosition: TimeInterval = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        configureAudioSession()
        installPlayerObservers()
        installRemoteCommands()
        installAudioSessionObservers()
    }

    /// True once an item is actually loaded in the player. A restored
    /// session shows a track before anything is loaded; the first play
    /// press resolves its stream instead of toggling an empty player.
    var hasLoadedItem: Bool { player.currentItem != nil }

    /// Session restore: put the track on display at the saved position
    /// without resolving a stream — that waits for the first play press.
    func restoreSession(track: MusicTrack, position savedPosition: TimeInterval) {
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTrack = track
        isPlaying = false
        isLoading = false
        errorMessage = nil
        position = max(0, savedPosition)
        duration = track.durationSeconds ?? 0
        publishNowPlaying()
    }

    func beginLoading(_ track: MusicTrack) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        isPlaying = false
        currentTrack = track
        isLoading = true
        errorMessage = nil
        position = 0
        duration = track.durationSeconds ?? 0
        publishNowPlaying()
    }

    func load(
        url: URL,
        headers: [String: String] = [:],
        track: MusicTrack,
        autoplay: Bool = true,
        startAt: TimeInterval = 0
    ) {
        loadInternal(
            url: url,
            headers: headers,
            track: track,
            autoplay: autoplay,
            startAt: startAt,
            useChunkedLoader: Self.shouldUseChunkedLoader(for: url)
        )
    }

    private func loadInternal(
        url: URL,
        headers: [String: String],
        track: MusicTrack,
        autoplay: Bool,
        startAt: TimeInterval,
        useChunkedLoader: Bool
    ) {
        removeItemObservers()
        currentTrack = track
        errorMessage = nil
        position = max(0, startAt)
        duration = track.durationSeconds ?? 0
        isLoading = true
        autoplayWhenReady = autoplay
        initialPosition = startAt.isFinite ? max(0, startAt) : 0

        let asset: AVURLAsset
        if useChunkedLoader, let loader = ChunkedResourceLoader(originalURL: url, headers: headers) {
            self.resourceLoader = loader
            let customAsset = AVURLAsset(url: loader.assetURL)
            customAsset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            asset = customAsset
        } else {
            let options: [String: Any] = headers.isEmpty
                ? [:]
                : ["AVURLAssetHTTPHeaderFieldsKey": headers]
            asset = AVURLAsset(url: url, options: options)
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    let seconds = observedItem.duration.seconds
                    if seconds.isFinite && seconds > 0 { self.duration = seconds }
                    self.startReadyItem()
                    self.publishNowPlaying()
                case .failed:
                    if useChunkedLoader && self.position < 1 {
                        self.loadInternal(
                            url: url,
                            headers: headers,
                            track: track,
                            autoplay: autoplay,
                            startAt: startAt,
                            useChunkedLoader: false
                        )
                        return
                    }
                    if let onLoadFailure = self.onLoadFailure {
                        onLoadFailure(observedItem.error)
                    } else {
                        self.isLoading = false
                        self.errorMessage = Self.message(for: observedItem.error)
                        self.publishNowPlaying()
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onItemEnded?() }
        }
        publishNowPlaying()
    }

    private static func shouldUseChunkedLoader(for url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.contains("/manifest/") {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        return host.contains("googlevideo.com") || path.contains("videoplayback")
    }

    func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
        publishNowPlaying()
    }

    /// What the user is told when a stream will not load.
    ///
    /// AVFoundation's own wording for a refused URL is "An unknown error
    /// occurred.", which says nothing at all: the refusal is named
    /// instead, so the message is worth reading.
    static func message(for error: Error?) -> String {
        guard let error else { return "This audio file could not be played." }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorUnknown {
            return "YouTube refused this stream. Try the track again."
        }
        return failure.localizedDescription
    }

    func play() {
        guard player.currentItem != nil else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { /* playback will surface item errors */ }
        // `play()` would force rate 1.0; going through the rate keeps a
        // chosen playback speed across pause/resume.
        player.rate = desiredRate
        publishNowPlaying()
    }

    func pause() {
        player.pause()
        publishNowPlaying()
    }

    /// Playback speed, clamped to the 0.5×–2.0× range Android offers.
    /// Applies immediately when something is playing; otherwise it is the
    /// rate the next `play()` (or freshly loaded item) starts at.
    func setRate(_ newRate: Float) {
        let clamped = min(max(newRate, 0.5), 2.0)
        desiredRate = clamped
        rate = clamped
        if isPlaying { player.rate = clamped }
        publishNowPlaying()
    }

    /// The player's own gain, under the system volume — what the crossfade
    /// ramp breathes with. Not a user volume control (the mini player uses
    /// `MPVolumeView` for that, like Apple Music).
    func setVolume(_ newVolume: Float) {
        player.volume = min(max(newVolume, 0), 1)
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        position = max(0, seconds)
        publishNowPlaying()
    }

    func synchronize(isPlaying shouldPlay: Bool, position target: TimeInterval) {
        guard target.isFinite else { return }
        let safeTarget = max(0, target)
        guard let item = player.currentItem, item.status == .readyToPlay else {
            autoplayWhenReady = shouldPlay
            initialPosition = safeTarget
            position = safeTarget
            publishNowPlaying()
            return
        }
        if abs(position - safeTarget) > 1.5 { seek(to: safeTarget) }
        if shouldPlay { play() } else { pause() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        currentTrack = nil
        isPlaying = false
        isLoading = false
        position = 0
        duration = 0
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = nil
        loadingArtworkForID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func startReadyItem() {
        let startAt = initialPosition
        initialPosition = 0
        let shouldPlay = autoplayWhenReady
        guard startAt > 0 else {
            if shouldPlay { player.rate = desiredRate } else { player.pause() }
            return
        }
        let time = CMTime(seconds: startAt, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if shouldPlay { self.player.rate = self.desiredRate } else { self.player.pause() }
            }
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            errorMessage = "Audio playback could not be activated: \(error.localizedDescription)"
        }
    }

    private func installPlayerObservers() {
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            let itemStatus = observedPlayer.currentItem?.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isLoading = status == .waitingToPlayAtSpecifiedRate && itemStatus != .failed
                self.publishNowPlaying()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.35, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                let loadedDuration = self.player.currentItem?.duration.seconds ?? 0
                if seconds.isFinite { self.position = max(0, seconds) }
                if loadedDuration.isFinite && loadedDuration > 0 { self.duration = loadedDuration }
                self.publishNowPlaying()
            }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append(center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let command = self.onPlayCommand { command() } else { self.play() }
            }
            return .success
        })
        remoteTargets.append(center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let command = self.onPauseCommand { command() } else { self.pause() }
            }
            return .success
        })
        remoteTargets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let command = self.onTogglePlaybackCommand { command() } else { self.togglePlayback() }
            }
            return .success
        })
        remoteTargets.append(center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let command = self.onNextTrackCommand { command() } else { self.onItemEnded?() }
            }
            return .success
        })
        remoteTargets.append(center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPreviousTrack?() }
            return .success
        })
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let command = self.onSeekCommand { command(event.positionTime) }
                else { self.seek(to: event.positionTime) }
            }
            return .success
        })
    }

    private func installAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .began { self.pause() }
                else if shouldResume { self.play() }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor [weak self] in self?.pause() }
            }
        }
    }

    private func publishNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0
        ]
        if let albumName = track.albumName { info[MPMediaItemPropertyAlbumTitle] = albumName }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        loadLockScreenArtwork(for: track)
    }

    private func loadLockScreenArtwork(for track: MusicTrack) {
        guard loadingArtworkForID != track.id,
              let raw = track.artworkURL,
              let url = URL(string: raw) else { return }
        loadingArtworkForID = track.id
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.currentTrack?.id == track.id else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func removeItemObservers() {
        resourceLoader?.cancelAll()
        resourceLoader = nil
        itemObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        resourceLoader?.cancelAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }
}

/// Bounded byte-range `AVAssetResourceLoaderDelegate` for `googlevideo.com`
/// streams (iOS counterpart to Android's `ChunkedDataSource` and Desktop's
/// `DesktopRangeStream`).
///
/// `AVURLAsset` otherwise hands the URL to `mediaserverd`, which fetches the
/// whole file in a single open-ended range with an `AppleCoreMedia`
/// User-Agent — a shape `googlevideo.com` throttles to ~15 KB/s or refuses
/// outright with HTTP 403. Fetching 512 KiB windows over `URLSession` with
/// the minting client's headers keeps every request bounded and authenticated.
final class ChunkedResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let customScheme = "bitchord-stream"
    private static let windowBytes = 524_288
    private static let maxCachedWindows = 24
    private static let maxRetries = 3

    let originalURL: URL
    let assetURL: URL
    let headers: [String: String]
    let delegateQueue = DispatchQueue(label: "com.music.bitchord.resource-loader")

    private let session: URLSession
    private var totalLength: Int64?
    private var isVideoContainer = false
    private var windows: [Int64: Data] = [:]
    private var windowOrder: [Int64] = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init?(
        originalURL: URL,
        headers: [String: String],
        session: URLSession = .shared
    ) {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = Self.customScheme
        guard let rewritten = components.url else { return nil }
        self.originalURL = originalURL
        self.assetURL = rewritten
        self.headers = headers
        self.session = session
        if let clen = components.queryItems?.first(where: { $0.name == "clen" })?.value,
           let parsed = Int64(clen), parsed > 0 {
            self.totalLength = parsed
        }
        if let mime = components.queryItems?.first(where: { $0.name == "mime" })?.value,
           mime.lowercased().contains("video") {
            self.isVideoContainer = true
        }
        super.init()
    }

    func cancelAll() {
        delegateQueue.async { [weak self] in
            guard let self else { return }
            for (_, task) in self.tasks {
                task.cancel()
            }
            self.tasks.removeAll()
            self.windows.removeAll()
            self.windowOrder.removeAll()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.fulfill(loadingRequest)
        }
        tasks[id] = task
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        let id = ObjectIdentifier(loadingRequest)
        defer {
            delegateQueue.async { [weak self] in
                self?.tasks[id] = nil
            }
        }

        do {
            let startOffset: Int64 = delegateQueue.sync {
                if let dataRequest = loadingRequest.dataRequest {
                    return dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
                }
                return 0
            }

            let needsContentInfo: Bool = delegateQueue.sync {
                loadingRequest.contentInformationRequest != nil && self.totalLength == nil
            }
            if needsContentInfo {
                let firstWindowStart = (max(0, startOffset) / Int64(Self.windowBytes)) * Int64(Self.windowBytes)
                _ = try await fetchWindow(startingAt: firstWindowStart)
            }

            delegateQueue.sync {
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = (self.isVideoContainer ? AVFileType.mp4 : AVFileType.m4a).rawValue
                    info.isByteRangeAccessSupported = true
                    if let totalLength = self.totalLength {
                        info.contentLength = totalLength
                    }
                }
            }

            let dataParams: (start: Int64, length: Int, toEnd: Bool)? = delegateQueue.sync {
                guard let dataRequest = loadingRequest.dataRequest else { return nil }
                let start = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
                return (start, dataRequest.requestedLength, dataRequest.requestsAllDataToEndOfResource)
            }

            if let dataParams {
                var cursor = max(0, dataParams.start)
                var targetEnd: Int64 = delegateQueue.sync {
                    if dataParams.toEnd {
                        return self.totalLength ?? Int64.max
                    }
                    let requestedEnd = dataParams.start + Int64(dataParams.length)
                    if let total = self.totalLength {
                        return min(requestedEnd, total)
                    }
                    return requestedEnd
                }

                while cursor < targetEnd {
                    if Task.isCancelled { return }
                    let isCancelled: Bool = delegateQueue.sync {
                        loadingRequest.isCancelled || loadingRequest.isFinished
                    }
                    if isCancelled { return }

                    let windowStart = (cursor / Int64(Self.windowBytes)) * Int64(Self.windowBytes)
                    let windowData = try await fetchWindow(startingAt: windowStart)
                    if windowData.isEmpty { break }

                    targetEnd = delegateQueue.sync {
                        if let info = loadingRequest.contentInformationRequest,
                           let total = self.totalLength {
                            info.contentLength = total
                        }
                        if dataParams.toEnd {
                            return self.totalLength ?? Int64.max
                        }
                        let requestedEnd = dataParams.start + Int64(dataParams.length)
                        if let total = self.totalLength {
                            return min(requestedEnd, total)
                        }
                        return requestedEnd
                    }

                    let offsetInWindow = Int(cursor - windowStart)
                    guard offsetInWindow >= 0 && offsetInWindow < windowData.count else { break }
                    let available = windowData.count - offsetInWindow
                    let remaining = targetEnd - cursor
                    guard remaining > 0 else { break }
                    let count = Int(min(Int64(available), remaining))
                    let slice = windowData.subdata(in: offsetInWindow..<(offsetInWindow + count))

                    let shouldStop: Bool = delegateQueue.sync {
                        guard !loadingRequest.isCancelled && !loadingRequest.isFinished else { return true }
                        loadingRequest.dataRequest?.respond(with: slice)
                        return false
                    }
                    if shouldStop { return }

                    cursor += Int64(count)
                    if windowData.count < Self.windowBytes && self.totalLength == nil {
                        break
                    }
                }
            }

            delegateQueue.sync {
                guard !loadingRequest.isCancelled && !loadingRequest.isFinished else { return }
                loadingRequest.finishLoading()
            }
        } catch {
            delegateQueue.sync {
                guard !loadingRequest.isCancelled && !loadingRequest.isFinished else { return }
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    private func fetchWindow(startingAt windowStart: Int64) async throws -> Data {
        if let cached: Data = delegateQueue.sync(execute: { windows[windowStart] }) {
            return cached
        }

        let knownTotal: Int64? = delegateQueue.sync { totalLength }
        if let knownTotal, windowStart >= knownTotal {
            return Data()
        }

        let rawEnd = windowStart + Int64(Self.windowBytes) - 1
        let windowEnd = knownTotal.map { min(rawEnd, $0 - 1) } ?? rawEnd
        guard windowEnd >= windowStart else { return Data() }

        var lastError: Error = MusicRequestError.noPlayableStream
        for attempt in 0..<Self.maxRetries {
            if Task.isCancelled { throw CancellationError() }
            var request = URLRequest(url: originalURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("bytes=\(windowStart)-\(windowEnd)", forHTTPHeaderField: "Range")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw MusicRequestError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw MusicRequestError.httpStatus(http.statusCode)
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.hasPrefix("text/") {
                    throw MusicRequestError.noPlayableStream
                }
                let parsedTotal = Self.parseTotalLength(from: http, fallbackDataCount: data.count, windowStart: windowStart)
                let isVideo = contentType.contains("video/")
                delegateQueue.sync {
                    if let parsedTotal, parsedTotal > 0 {
                        self.totalLength = parsedTotal
                    }
                    if isVideo {
                        self.isVideoContainer = true
                    }
                    self.storeWindow(data, at: windowStart)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt + 1 < Self.maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private func storeWindow(_ data: Data, at windowStart: Int64) {
        windows[windowStart] = data
        windowOrder.removeAll { $0 == windowStart }
        windowOrder.append(windowStart)
        while windowOrder.count > Self.maxCachedWindows {
            let oldest = windowOrder.removeFirst()
            windows.removeValue(forKey: oldest)
        }
    }

    static func parseTotalLength(
        from response: HTTPURLResponse,
        fallbackDataCount: Int,
        windowStart: Int64
    ) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalPart = contentRange[contentRange.index(after: slash)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let total = Int64(totalPart), total > 0 {
                return total
            }
        }
        if response.statusCode == 200,
           let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(contentLength), total > 0 {
            return total
        }
        if windowStart == 0 && response.statusCode == 200 && fallbackDataCount > 0 {
            return Int64(fallbackDataCount)
        }
        return nil
    }
}
