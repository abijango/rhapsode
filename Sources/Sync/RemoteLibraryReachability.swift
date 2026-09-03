import Foundation
import Network

/// Tracks whether the device has a usable network path (Wi‑Fi, cellular, VPN).
///
/// Selective-catalog shelves hide grey remote tiles when offline so users are not
/// shown titles they cannot reach or download.
@MainActor
final class RemoteLibraryReachability {
    private var monitor: NWPathMonitor?

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                onChange(online)
            }
        }
        m.start(queue: DispatchQueue(label: "com.naufalmir.rhapsode.reachability"))
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
