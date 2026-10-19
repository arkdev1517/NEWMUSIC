import Combine
import Foundation
import Network

/// Watches the active network path so per-network audio quality and the
/// Wi-Fi-only download rule can follow the connection, the way Android's
/// `meteredConnection` flow follows `ConnectivityManager`.
///
/// `isMetered` is `nil` until the first path update arrives; callers treat an
/// unknown path as unmetered, matching Android's fail-open behaviour.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isMetered: Bool?
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.music.bitchord.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let metered = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                guard let self else { return }
                isOnline = online
                isMetered = metered
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
