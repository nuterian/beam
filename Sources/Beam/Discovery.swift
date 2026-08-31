import Foundation
import Network
import BeamCore

/// Presence: advertise this instance as `_beam._tcp`, browse for others, and
/// accept the connections a peer's join gesture opens.
///
/// A Local Network (TCC) denial must surface as its own explicit state, never
/// as an empty peer list — that is the one macOS failure §2 singles out,
/// because it looks exactly like "nobody else is running Beam" on precisely
/// one tester's machine.
final class DiscoveryService {
    private let serviceType = "_beam._tcp"
    private let ownName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "beam.discovery")
    /// First-seen time per peer name, so a peer's row keeps its number and its
    /// fade does not restart every time the browser republishes its results.
    private var firstSeen: [String: Double] = [:]

    /// Ordered peer list, main queue. Order is first-seen and stable: the
    /// number under your finger must still be the peer you read.
    var onPeersChanged: (([Peer]) -> Void)?
    var onPresenceProblem: ((AppModel.PresenceState) -> Void)?
    /// A peer dialled us. Main queue.
    var onInboundConnection: ((NWConnection) -> Void)?

    init(ownName: String) {
        self.ownName = ownName
    }

    /// The advertised name: hostname plus pid, so two instances on one machine
    /// (the bench, and any real two-window test) stay distinct on the wire
    /// while the roster still shows just the machine.
    static func defaultName() -> String {
        let host = Host.current().localizedName ?? "beam"
        let safe = host.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return "\(String(safe))-\(getpid())"
    }

    func start() {
        do {
            // Ephemeral-port listeners need allowLocalEndpointReuse (EINVAL otherwise).
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: ownName, type: serviceType)
            // A listener with no newConnectionHandler fails EINVAL at start.
            l.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { self?.onInboundConnection?(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.problem(.advertiseFailed) }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            problem(.advertiseFailed)
        }

        startBrowser()
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting: self?.problem(.localNetworkDenied)
            default: break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    /// Stop browsing. Intended for "a session is live, so nobody is looking at
    /// the roster" — the leading candidate for the last ~0.1% of connected idle
    /// CPU (PLAN.md §5.1). Deliberately NOT wired up yet: the display went dark
    /// before it could be measured, and an unmeasured optimisation is not
    /// something this project merges. Advertising would continue regardless —
    /// peers must still be able to find this machine.
    func pauseBrowsing() {
        browser?.cancel()
        browser = nil
    }

    func resumeBrowsing() {
        guard browser == nil else { return }
        firstSeen.removeAll()  // rejoining the roster is a fresh arrival, and fades in as one
        startBrowser()
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var peers: [Peer] = []
        let now = monotonicNow()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name != ownName else { continue }
            let seen = firstSeen[name] ?? now
            firstSeen[name] = seen
            peers.append(Peer(name: name, endpoint: r.endpoint, appearedAt: seen, inkIndex: Peer.ink(of: name)))
        }
        peers.sort { ($0.appearedAt, $0.name) < ($1.appearedAt, $1.name) }
        if ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1" {
            FileHandle.standardError.write("browse: \(results.count) results -> \(peers.map(\.name))\n".data(using: .utf8)!)
        }
        let deliver: () -> Void = { [weak self] in self?.onPeersChanged?(peers) }
        if Sabotage.peerListDelayMs > 0 {
            // Proves L1.launch_to_peers_visible_ms can go red: the peer is on
            // the network, we simply take too long to put it on the glass.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Sabotage.peerListDelayMs), execute: deliver)
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func problem(_ state: AppModel.PresenceState) {
        DispatchQueue.main.async { self.onPresenceProblem?(state) }
    }
}
