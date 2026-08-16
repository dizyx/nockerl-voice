import Foundation
import Network

/// Push-based internet reachability, via the system's `NWPathMonitor`: the OS calls us when
/// connectivity changes, so there is NO polling and no timer.
///
/// Scope note: a satisfied path means a usable ROUTE exists, not that the internet works
/// (captive portals, DNS failures and provider outages all still look satisfied). So this is
/// trustworthy for "definitely offline" and only suggestive for "online". It is used to
/// EXPLAIN failures, never to gate a request. A request is always attempted; if it fails while
/// `isOnline == false`, the user is told they're offline instead of blaming the server.
///
/// It also does not describe the Custom/local tier: that model is reached over Tailscale, which
/// can be up while the public internet is down (and vice versa). Only the cloud tier reads this.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// False only when the system reports no usable path. Starts optimistic so nothing is
    /// mislabeled offline during the first callback.
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dizyx.nockerlvoice.network-monitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                DebugLog.write("network: \(online ? "online" : "OFFLINE")")
            }
        }
        monitor.start(queue: queue)
    }
}
