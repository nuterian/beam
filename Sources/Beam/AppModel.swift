import Foundation
import Network
import BeamCore

/// A peer discovered on the LAN.
struct Peer {
    /// Advertised Bonjour name — unique, used for identity and self-exclusion.
    let name: String
    let endpoint: NWEndpoint
    /// When it first appeared, for the fade-in.
    let appearedAt: Double
    /// The palette slot this peer is actually shown in. Starts at the hash of
    /// the name and moves only to break a tie — see `assignInks`.
    var inkIndex: Int

    var display: String { Peer.display(of: name) }

    /// The name a human reads. The advertised name carries a `-<pid>` suffix so
    /// two instances on one machine stay distinguishable to the protocol; the
    /// roster shows the machine.
    static func display(of name: String) -> String {
        guard let dash = name.lastIndex(of: "-"),
              !name[name.index(after: dash)...].isEmpty,
              name[name.index(after: dash)...].allSatisfy(\.isNumber) else { return name }
        return String(name[..<dash])
    }

    /// Deterministic from the name, so both ends pick the same colour for each
    /// other without negotiating anything.
    static func ink(of name: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(Renderer.Ink.peerCount))
    }

    /// The hash alone gives two of three peers the same colour often enough to
    /// see it on the launch screen (six slots, birthday paradox — measured on
    /// the very first roster screenshot of this session). The six peer hues are
    /// designed as a *set*, so two rows sharing one is the design failing, not
    /// a cosmetic near-miss.
    ///
    /// So: the hash is the preferred slot, and collisions probe forward to the
    /// next free one. Sorting by name first makes the outcome depend only on
    /// *which* peers are present, never on discovery order, so a roster does
    /// not reshuffle its colours as it fills in. Past six peers slots have to
    /// repeat, and they do, in a defined order rather than at random.
    ///
    /// Phase 4 (N-peer) needs colours that agree across machines; that is a
    /// negotiation, and it is not this. In a 1:1 session each side colours only
    /// the *other* peer, so nothing has to agree yet.
    static func assignInks(_ peers: inout [Peer]) {
        var taken = Set<Int>()
        for i in peers.indices.sorted(by: { peers[$0].name < peers[$1].name }) {
            var slot = Peer.ink(of: peers[i].name)
            var probes = 0
            while taken.contains(slot) && probes < Renderer.Ink.peerCount {
                slot = (slot + 1) % Renderer.Ink.peerCount
                probes += 1
            }
            taken.insert(slot)
            peers[i].inkIndex = slot
        }
    }
}

/// A peer's cursor in the shared grid.
struct RemoteCursor {
    var cursor = GridModel.Cursor()
    var name = ""
    var inkIndex = 0
    var since = monotonicNow()
}

/// The whole shell: three surfaces, four keys, one state machine. Everything a
/// frame needs to draw hangs off this; GridView owns only the render loop and
/// input. See PLAN.md §5.1.
final class AppModel {
    enum Surface {
        case roster       // the launch screen IS the peer list
        case pairing      // six digits on both screens, awaiting the host's return
        case editor
    }

    /// Why the roster might be empty. Never conflated: a permission denial that
    /// looks like an empty network is the exact failure §2 forbids.
    enum PresenceState {
        case searching
        case ok
        case localNetworkDenied
        case advertiseFailed
    }

    private(set) var surface: Surface = .roster
    private(set) var peers: [Peer] = []
    private(set) var presence: PresenceState = .searching
    private(set) var session: Session?
    /// Name of the peer being joined, shown the instant the gesture lands —
    /// before a single network byte moves (PLAN.md §5.1, sub-frame ack).
    private(set) var joiningName = ""
    private(set) var joiningInk = 0
    /// Set when this side made the gesture (guest) vs. received it (host).
    private(set) var isHost = false
    private(set) var remote: RemoteCursor?
    /// Whether the six digits have actually reached THIS screen. The guest is
    /// the side doing the comparing, so it must not be dropped into the editor
    /// before it has had the code to compare — otherwise a fast host (or an
    /// automated one) could complete a join the guest's human never saw. Set
    /// from the present handler, so it means "on the glass", not "in the model".
    private(set) var codePresented = false
    private var acceptPending = false

    let grid = GridModel()
    let localName: String
    var discovery: DiscoveryService?

    /// Repaint request. Set by GridView.
    var onNeedsRender: (() -> Void)?
    /// Repaint for a changed status value (a peer's RTT) — one frame, and the
    /// render loop goes straight back to sleep. Set by GridView.
    var onNeedsStatusRender: (() -> Void)?
    /// A remote op changed the document; carries the sender's uptime as t0 so
    /// the frame it lands in can be attributed to it (loopback E2E row).
    var onRemoteEdit: ((Double) -> Void)?

    // Bench hooks (main queue) — the benches observe, they never drive.
    var onPeersChanged: (() -> Void)?
    var onPairingReady: (() -> Void)?
    var onEditingReady: (() -> Void)?
    var onSessionOp: ((Session.Inbound) -> Void)?

    /// Fades run for this long and then stop. Finite by rule: an animation that
    /// never ends would pin the display link awake and put a permanent floor
    /// under idle CPU (PLAN.md §5.1, "nothing blinks").
    static let fadeSeconds = 0.20

    init(localName: String) {
        self.localName = localName
    }

    // MARK: - Presence

    /// Bench/calibration modes that measure the local render path start on the
    /// editor with no session and no discovery, so their numbers stay directly
    /// comparable with every Phase-0/1 run (PLAN.md §5-L2).
    func startInEditor() {
        surface = .editor
    }

    func startDiscovery() {
        let d = DiscoveryService(ownName: localName)
        d.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            var peers = peers
            Peer.assignInks(&peers)
            self.peers = peers
            if case .searching = self.presence, !peers.isEmpty { self.presence = .ok }
            self.onNeedsRender?()
            self.onPeersChanged?()
        }
        d.onPresenceProblem = { [weak self] state in
            guard let self else { return }
            self.presence = state
            self.onNeedsRender?()
        }
        d.onInboundConnection = { [weak self] conn in
            self?.hostReceived(conn)
        }
        d.start()
        discovery = d
    }

    // MARK: - The gesture

    /// Guest side. Returns false if the index does not name a peer — the caller
    /// (a click or a number key) then does nothing at all, silently.
    @discardableResult
    func join(peerIndex: Int) -> Bool {
        guard surface == .roster, peerIndex >= 0, peerIndex < peers.count else {
            if ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1" {
                FileHandle.standardError.write("join(\(peerIndex)) refused: peers=\(peers.count)\n".data(using: .utf8)!)
            }
            return false
        }
        let peer = peers[peerIndex]
        isHost = false
        codePresented = false
        acceptPending = false
        joiningName = peer.display
        joiningInk = peer.inkIndex
        surface = .pairing
        // Repaint FIRST: the acknowledgment is local, so the connection feels
        // instant even though the code is still a round trip away.
        onNeedsRender?()

        let s = Session(connectingTo: peer.endpoint, localName: localName)
        wire(s)
        session = s
        s.start()
        return true
    }

    /// Host side: someone made the gesture at us.
    private func hostReceived(_ conn: NWConnection) {
        guard surface == .roster, session == nil else {
            conn.cancel()  // one session at a time in Phase 2; N-peer is Phase 4
            return
        }
        isHost = true
        codePresented = false
        acceptPending = false
        joiningName = "a peer"
        surface = .pairing
        onNeedsRender?()

        let s = Session(accepting: conn, localName: localName)
        wire(s)
        session = s
        s.start()
    }

    private func wire(_ s: Session) {
        s.onPaired = { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.peerName.isEmpty {
                self.joiningName = Peer.display(of: s.peerName)
                self.joiningInk = Peer.ink(of: s.peerName)
            }
            self.onNeedsRender?()
            self.onPairingReady?()
        }
        s.onAccepted = { [weak self] in
            guard let self else { return }
            // Hold the acceptance until this side has shown the code.
            if self.codePresented { self.enterEditor() } else { self.acceptPending = true }
        }
        s.onClosed = { [weak self] _ in self?.leaveSession() }
        s.onOp = { [weak self] inbound in
            self?.apply(inbound)
            self?.onSessionOp?(inbound)
        }
    }

    /// The join code reached the glass on this side.
    func noteCodePresented() {
        guard !codePresented else { return }
        codePresented = true
        if acceptPending { acceptPending = false; enterEditor() }
    }

    /// Host confirms the six digits match. One keypress; the whole security
    /// model rests on a human having compared them.
    func confirmJoin() {
        guard surface == .pairing, isHost, let s = session, !s.sas.isEmpty else { return }
        s.send(.accept)
        enterEditor()
    }

    /// Either side, at any time.
    func leaveSession() {
        session?.cancel()
        session = nil
        remote = nil
        codePresented = false
        acceptPending = false
        joiningName = ""
        surface = .roster
        onNeedsRender?()
    }

    private func enterEditor() {
        guard surface == .pairing, let s = session else { return }
        surface = .editor
        remote = RemoteCursor(cursor: .init(), name: joiningName, inkIndex: joiningInk, since: monotonicNow())
        s.startRTTProbe()
        s.send(.hello, Session.u16Bytes(grid.cursor.col) + Session.u16Bytes(grid.cursor.row))
        onNeedsRender?()
        onEditingReady?()
    }

    // MARK: - Editing

    /// Local keystroke already applied to the grid — mirror it to the peer.
    /// Called from the keystroke hot path, after the local render is under way.
    func publishLocal(_ op: Session.Op, _ payload: [UInt8] = []) {
        guard surface == .editor else { return }
        session?.send(op, payload)
    }

    private func apply(_ inbound: Session.Inbound) {
        if inbound.op == .pong { onNeedsRenderIfRTTChanged(); return }
        guard surface == .editor, var r = remote else { return }
        // Edit ops lead with the sender's uptime (see `editPayload`), so the
        // frame they land in can be attributed to the keystroke that caused it.
        switch inbound.op {
        case .insert:
            guard inbound.bytes.count >= 9 else { return }
            grid.typeAscii(inbound.bytes[8], at: &r.cursor)
        case .newline:
            grid.newline(at: &r.cursor)
        case .backspace:
            grid.backspace(at: &r.cursor)
        case .cursor, .hello:
            r.cursor.col = Session.readU16(inbound.bytes, 0)
            r.cursor.row = Session.readU16(inbound.bytes, 2)
            remote = r
            onNeedsRender?()
            return
        default:
            return
        }
        remote = r
        let t0 = Session.readDouble(inbound.bytes, 0)
        onRemoteEdit?(t0 > 0 ? t0 : monotonicNow())
    }

    /// Edit-op payload: the originating keystroke's timestamp, then the op's
    /// own bytes. Eight bytes per keystroke buys the peer a true one-way
    /// latency number to display — which is the whole latency-as-UI idea, and
    /// it is inside the 48-byte L6 wire budget with room to spare.
    static func editPayload(t0: Double, _ tail: [UInt8] = []) -> [UInt8] {
        Session.doubleBytes(t0) + tail
    }

    /// Live RTT is in the HUD, so it must not cost anything to display: repaint
    /// only when the number a human would read actually changes, never on a
    /// timer. `idle_cpu_connected_pct_core` is the gate that enforces this.
    private var lastShownRTT = ""
    private func onNeedsRenderIfRTTChanged() {
        let now = rttText
        guard now != lastShownRTT else { return }
        lastShownRTT = now
        onNeedsStatusRender?()
    }

    var rttText: String {
        guard let rtt = session?.rttMs else { return "" }
        return String(format: "%.1f ms", rtt)
    }

    /// True while any fade is still in flight — the display link stays awake
    /// exactly this long and not one tick more.
    func isAnimating(_ now: Double) -> Bool {
        switch surface {
        case .roster:
            return peers.contains { now - $0.appearedAt < Self.fadeSeconds }
        case .pairing:
            return false
        case .editor:
            return (remote.map { now - $0.since < Self.fadeSeconds }) ?? false
        }
    }

    // MARK: - Seams for --dump-scene (see SceneDump)

    func debugSetPresence(_ p: PresenceState) { presence = p }

    func debugSetPeers(_ names: [String]) {
        peers = names.map {
            Peer(name: $0,
                 endpoint: .service(name: $0, type: "_beam._tcp", domain: "local.", interface: nil),
                 appearedAt: 1, inkIndex: Peer.ink(of: $0))
        }
        Peer.assignInks(&peers)
        presence = .ok
    }

    func debugSetPairing(host: Bool) {
        surface = .pairing
        isHost = host
        joiningName = peers.first.map(\.display) ?? "a peer"
        joiningInk = peers.first?.inkIndex ?? 0
    }

    func debugSetEditing(text: String, peer: String, peerCursor: (Int, Int)) {
        surface = .editor
        for ch in text.utf8 {
            if ch == 10 { grid.newline() } else { grid.typeAscii(ch) }
        }
        remote = RemoteCursor(cursor: .init(col: peerCursor.0, row: peerCursor.1),
                              name: Peer.display(of: peer), inkIndex: Peer.ink(of: peer), since: 1)
    }

    /// A fade never starts from nothing. Two reasons, and the second is the
    /// serious one (PLAN.md §5.2, motion):
    ///
    /// 1. Starting at zero makes arrival feel *slower* than it is — the first
    ///    frame after a peer is discovered shows an empty row where the peer
    ///    is. From 40% the row is legible on frame one and the fade reads as
    ///    settling rather than as loading.
    /// 2. **A fade must not be able to make a "visible" claim true before a
    ///    human could read the thing.** `L1.launch_to_peers_visible_ms` is
    ///    marked on the presented frame that first carries a peer row; with a
    ///    fade from zero that frame is blank, and Beam would be quietly
    ///    crediting itself with up to a fade's worth of latency it had not
    ///    delivered. The floor is what makes the metric honest, which is why
    ///    it is a constant here and not a taste knob.
    static let fadeFloor = 0.40

    static func alpha(since: Double, now: Double) -> UInt8 {
        guard since > 0 else { return 255 }
        let t = (now - since) / fadeSeconds
        if t >= 1 { return 255 }
        // Ease-out: fast to mostly-there, so it reads as arrival, not as motion.
        let eased = t <= 0 ? 0 : 1 - (1 - t) * (1 - t)
        let a = fadeFloor + (1 - fadeFloor) * eased
        return UInt8(max(0, min(255, a * 255)))
    }
}
