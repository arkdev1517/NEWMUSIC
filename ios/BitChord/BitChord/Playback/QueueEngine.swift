import Foundation

/// The queue's ordering brain, kept as a value type so every transition is
/// unit-testable without a player. It mirrors the behaviour of Android's
/// `QueueCoordinator` + `QueueShuffle` reduced to the ordering rules the UI
/// can observe:
///
/// - the queue has a *play order* (`order`, indices into `tracks`) which is
///   the identity while shuffle is off;
/// - turning shuffle on pins the current track and shuffles the rest of the
///   order behind it; turning it off restores the original order around the
///   track that is playing — nothing is ever lost by toggling;
/// - repeat-one only engages on automatic advance (a manual skip still
///   skips), repeat-all wraps, and reaching the end with repeat off reports
///   `.finished` so the caller can decide about autoplay;
/// - "play next" inserts directly after the current position in the play
///   order, "add to queue" appends to the end of it.
struct QueueEngine: Sendable {
    private(set) var tracks: [MusicTrack] = []
    private(set) var order: [Int] = []
    private(set) var orderPosition: Int = 0
    var shuffleEnabled = false
    var repeatMode: RepeatMode = .off

    enum Advance: Equatable, Sendable {
        case playTrack
        case restartCurrent
        case finished
    }

    var isEmpty: Bool { tracks.isEmpty }

    var currentTrack: MusicTrack? {
        guard order.indices.contains(orderPosition) else { return nil }
        return tracks[order[orderPosition]]
    }

    /// The queue as the UI shows it: tracks in play order.
    var effectiveQueue: [MusicTrack] { order.map { tracks[$0] } }

    var effectiveIndex: Int { orderPosition }

    var hasNext: Bool { orderPosition + 1 < order.count || repeatMode == .all }
    var hasPrevious: Bool { orderPosition > 0 }

    mutating func setQueue(_ newTracks: [MusicTrack], startIndex: Int) {
        tracks = newTracks
        let start = min(max(startIndex, 0), max(0, newTracks.count - 1))
        if shuffleEnabled && !newTracks.isEmpty {
            var rest = Array(newTracks.indices).filter { $0 != start }
            rest.shuffle()
            order = [start] + rest
            orderPosition = 0
        } else {
            order = Array(newTracks.indices)
            orderPosition = start
        }
    }

    /// Sets the queue with the order preserved exactly as given, whatever the
    /// shuffle flag says (a Listen Together party's shared order is
    /// authoritative). The flag itself is untouched, so the user's own
    /// queues shuffle again once they are back in charge.
    mutating func setQueuePreservingOrder(_ newTracks: [MusicTrack], startIndex: Int) {
        tracks = newTracks
        order = Array(newTracks.indices)
        orderPosition = min(max(startIndex, 0), max(0, newTracks.count - 1))
    }

    mutating func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        shuffleEnabled = enabled
        guard !tracks.isEmpty else { return }
        let current = order.indices.contains(orderPosition) ? order[orderPosition] : 0
        if enabled {
            var rest = Array(tracks.indices).filter { $0 != current }
            rest.shuffle()
            order = [current] + rest
            orderPosition = 0
        } else {
            order = Array(tracks.indices)
            orderPosition = current
        }
    }

    /// Advances after the current track ends (auto) or the user skips
    /// (manual). Repeat-one restarts on auto-advance only.
    mutating func advance(manual: Bool) -> Advance {
        guard !order.isEmpty else { return .finished }
        if !manual && repeatMode == .one { return .restartCurrent }
        if orderPosition + 1 < order.count {
            orderPosition += 1
            return .playTrack
        }
        if repeatMode == .all {
            orderPosition = 0
            return .playTrack
        }
        return .finished
    }

    mutating func goPrevious() -> Bool {
        guard orderPosition > 0 else { return false }
        orderPosition -= 1
        return true
    }

    mutating func jump(toEffectiveIndex index: Int) -> Bool {
        guard order.indices.contains(index) else { return false }
        orderPosition = index
        return true
    }

    /// Inserts so the track plays immediately after the current one.
    mutating func insertNext(_ track: MusicTrack) {
        tracks.append(track)
        let newTrackIndex = tracks.count - 1
        if order.isEmpty {
            order = [newTrackIndex]
            orderPosition = 0
        } else {
            order.insert(newTrackIndex, at: orderPosition + 1)
        }
    }

    /// Appends to the end of the play order.
    mutating func appendToQueue(_ track: MusicTrack) {
        tracks.append(track)
        order.append(tracks.count - 1)
        if order.count == 1 { orderPosition = 0 }
    }

    mutating func appendToQueue(_ newTracks: [MusicTrack]) {
        for track in newTracks { appendToQueue(track) }
    }

    /// Removes the entry at an effective (play-order) index. Returns true
    /// when the removed entry was the current track, so the caller knows it
    /// must move playback on.
    @discardableResult
    mutating func remove(atEffectiveIndex index: Int) -> Bool {
        guard order.indices.contains(index) else { return false }
        let removedTrackIndex = order.remove(at: index)
        let wasCurrent = index == orderPosition
        tracks.remove(at: removedTrackIndex)
        // Re-index the order past the removed track.
        order = order.map { $0 > removedTrackIndex ? $0 - 1 : $0 }
        if index < orderPosition { orderPosition -= 1 }
        if orderPosition >= order.count { orderPosition = max(0, order.count - 1) }
        return wasCurrent
    }

    /// Moves an entry within the play order (queue drag-reorder).
    mutating func move(fromEffectiveIndex source: Int, toEffectiveIndex destination: Int) {
        guard order.indices.contains(source), order.indices.contains(destination), source != destination else { return }
        let currentTrackIndex = order.indices.contains(orderPosition) ? order[orderPosition] : nil
        let moved = order.remove(at: source)
        order.insert(moved, at: destination)
        if let currentTrackIndex, let newPosition = order.firstIndex(of: currentTrackIndex) {
            orderPosition = newPosition
        }
    }

    mutating func clear() {
        tracks = []
        order = []
        orderPosition = 0
    }
}
