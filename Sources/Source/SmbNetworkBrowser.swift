import Foundation
import Network

/// Discovers SMB-capable hosts on the LAN via Bonjour (`_smb._tcp`), similar to
/// VidHub’s “Available Shares” host list.
@MainActor
final class SmbNetworkBrowser: ObservableObject {
    struct DiscoveredHost: Identifiable, Hashable, Sendable {
        var id: String { "\(name)|\(host)" }
        var name: String
        var host: String
        var detail: String
    }

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?

    func start() {
        stop()
        isBrowsing = true
        hosts = []

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_smb._tcp", domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        b.stateUpdateHandler = { (_: NWBrowser.State) in
            // no-op
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let snapshot = results
            Task { @MainActor in
                self?.apply(snapshot)
            }
        }
        b.start(queue: DispatchQueue.main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredHost] = []
        for result in results {
            switch result.endpoint {
            case .service(name: let name, type: _, domain: let domain, interface: _):
                let hostName: String
                if name.lowercased().hasSuffix(".local") {
                    hostName = name
                } else if domain.hasPrefix("local") {
                    hostName = "\(name).local"
                } else {
                    hostName = name
                }
                found.append(DiscoveredHost(name: name, host: hostName, detail: hostName))
            case .hostPort(host: let host, port: _):
                let h: String
                switch host {
                case .name(let n, _):
                    h = n
                case .ipv4(let addr):
                    h = "\(addr)"
                case .ipv6(let addr):
                    h = "\(addr)"
                @unknown default:
                    continue
                }
                found.append(DiscoveredHost(name: h, host: h, detail: h))
            default:
                continue
            }
        }
        var seen = Set<String>()
        hosts = found
            .filter { seen.insert($0.host.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
