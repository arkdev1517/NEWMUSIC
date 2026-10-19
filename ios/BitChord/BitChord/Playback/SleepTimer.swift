import Combine
import Foundation

/// Sleep timer, ported from Android's `playback/SleepTimer.kt`.
///
/// A deadline rather than a countdown: nothing has to tick for the timer to
/// stay accurate, so it survives the player UI being dismissed, and any
/// observer can work out how long is left for itself. `Date` stands in for
/// Android's `elapsedRealtime` — iOS gives apps no user-visible clock to
/// wind, so wall-clock drift is not a practical concern here.
///
/// "After this song" is deliberately not expressed as a deadline of
/// duration-minus-position: seeking and queue edits would leave that number
/// wrong, whereas the track ending is an event the player reports.
@MainActor
final class SleepTimer: ObservableObject {
    /// Deadline, or nil when no fixed timer is set.
    @Published private(set) var deadline: Date?
    /// The preset that was chosen, so the picker can tick it. Nil when off.
    @Published private(set) var minutes: Int?
    /// Pause when the current track ends instead of after a fixed wait.
    @Published private(set) var afterTrack = false

    /// Durations offered in the picker (Android's `PRESETS`).
    static let presets = [15, 30, 45, 60]

    var isRunning: Bool { deadline != nil || afterTrack }

    func start(minutes: Int) {
        afterTrack = false
        self.minutes = minutes
        deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func startAfterTrack() {
        minutes = nil
        deadline = nil
        afterTrack = true
    }

    func cancel() {
        minutes = nil
        deadline = nil
        afterTrack = false
    }

    /// How long is left, or nil when no fixed timer is running.
    var remaining: TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// True once a fixed deadline has passed.
    var isExpired: Bool {
        guard let deadline else { return false }
        return Date() >= deadline
    }

    var summary: String? {
        if afterTrack { return "After this song" }
        guard let remaining else { return nil }
        let total = Int(remaining.rounded(.up))
        if total >= 60 { return "\(total / 60)m left" }
        return "\(total)s left"
    }
}
