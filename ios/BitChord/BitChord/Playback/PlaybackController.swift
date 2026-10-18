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

    var onItemEnded: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onPlayCommand: (() -> Void)?
    var onPauseCommand: (() -> Void)?
    var onTogglePlaybackCommand: (() -> Void)?
    var onSeekCommand: ((TimeInterval) -> Void)?

    private let player = AVPlayer()
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
        removeItemObservers()
        currentTrack = track
        errorMessage = nil
        position = max(0, startAt)
        duration = track.durationSeconds ?? 0
        isLoading = true
        autoplayWhenReady = autoplay
        initialPosition = startAt.isFinite ? max(0, startAt) : 0

        let options: [String: Any] = headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let failure = observedItem.error?.localizedDescription
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
                    self.isLoading = false
                    self.errorMessage = failure ?? "This audio file could not be played."
                    self.publishNowPlaying()
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

    func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
        publishNowPlaying()
    }

    func play() {
        guard player.currentItem != nil else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { /* playback will surface item errors */ }
        player.play()
        publishNowPlaying()
    }

    func pause() {
        player.pause()
        publishNowPlaying()
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
            if shouldPlay { player.play() } else { player.pause() }
            return
        }
        let time = CMTime(seconds: startAt, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if shouldPlay { self.player.play() } else { self.player.pause() }
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
            Task { @MainActor [weak self] in self?.onItemEnded?() }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
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
        itemObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }
}
