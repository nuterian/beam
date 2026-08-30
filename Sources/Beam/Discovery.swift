import Foundation
import Network

/// Phase-0 presence: advertise this instance as _beam._tcp and browse for
/// others. Peer count (and any Local Network permission trouble) surfaces in
/// the HUD status — a TCC denial must never look like an empty network
/// (PLAN.md §2).
final class DiscoveryService {
    private let serviceType = "_beam._tcp"
    private let ownName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "beam.discovery")

    /// (peerCount, warningOrNil) — delivered on the main queue.
    var onChange: ((Int, String?) -> Void)?

    init() {
        let host = Host.current().localizedName ?? "beam"
        ownName = "\(host)-\(getpid())"
    }

    func start() {
        do {
            // Ephemeral-port listeners need allowLocalEndpointReuse (EINVAL otherwise).
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: ownName, type: serviceType)
            l.newConnectionHandler = { conn in conn.cancel() }  // Phase 2 wires sessions
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.report(warning: "advertise failed") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            report(warning: "advertise failed")
        }

        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results.filter {
                if case let .service(name, _, _, _) = $0.endpoint { return name != self.ownName }
                return false
            }
            self.report(count: peers.count)
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting:
                self?.report(warning: "local network permission? Settings > Privacy > Local Network")
            default: break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private var lastCount = 0
    private func report(count: Int? = nil, warning: String? = nil) {
        if let count { lastCount = count }
        let c = lastCount
        DispatchQueue.main.async { self.onChange?(c, warning) }
    }
}
