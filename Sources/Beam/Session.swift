import Foundation
import Network
import CryptoKit
import BeamCore

/// One encrypted peer session (PLAN.md §5.1).
///
/// Wire, in order:
///   1. Both sides send `BEAM` | version | X25519 ephemeral public key | name.
///   2. Both derive the shared secret, then via HKDF-SHA256: two directional
///      ChaChaPoly keys and a 6-digit short authentication string (SAS).
///   3. Both screens show the SAS; the host's return sends `accept`.
///   4. Everything after step 1 is `[u32 length][ChaChaPoly ciphertext‖tag]`.
///
/// The SAS is derived from BOTH public keys, so a machine-in-the-middle cannot
/// make the two screens agree — the human comparing six digits IS the
/// authentication. Keys are ephemeral per join (forward secrecy by
/// construction) and nonces are per-direction counters (no in-session replay).
final class Session {
    enum Role { case initiator, responder }

    enum Op: UInt8 {
        case insert = 0x01      // [u8 ascii]
        case newline = 0x02
        case backspace = 0x03
        case cursor = 0x04      // [u16 col][u16 row]
        case ping = 0x05        // [f64 senderUptime]
        case pong = 0x06        // [f64 senderUptime]
        case accept = 0x10
        case hello = 0x11       // [u16 col][u16 row] — initial cursor
        case benchMark = 0x7f   // [u8 kind][f64 a][f64 b] — bench only
    }

    /// A decoded inbound op. `t0` is the sender's uptime for ops that carry
    /// one; on one machine that is directly comparable (same mach clock), which
    /// is exactly why the loopback E2E row is legitimate and the cross-machine
    /// rows still must use RTT decomposition (PLAN.md §3.1).
    struct Inbound {
        let op: Op
        let bytes: [UInt8]
        let t0: Double
    }

    let role: Role
    private(set) var peerName = ""
    /// The six digits both humans compare. Empty until the handshake completes.
    private(set) var sas = ""
    /// X25519 + HKDF cost on the join path, ms (gated: L5.handshake_crypto_cpu_ms).
    private(set) var cryptoCpuMs: Double = 0
    /// Deterministic counter: bytes handed to the socket, ciphertext included.
    /// Written on the session queue, so read it through `bytesSentSync()`.
    private(set) var bytesSent = 0
    /// Bench-only, and worth the hop: reading the counter straight off another
    /// queue would silently under-count a deterministic metric.
    func bytesSentSync() -> Int { queue.sync { bytesSent } }
    /// Live round-trip time to this peer, ms — the number in the HUD. Reported
    /// as a rolling median rather than the last sample: a number that jitters
    /// every probe would repaint every probe, and repainting on a timer is the
    /// thing `idle_cpu_connected_pct_core` exists to forbid.
    var rttMs: Double? {
        guard !rttWindow.isEmpty else { return nil }
        return rttWindow.sorted()[rttWindow.count / 2]
    }
    private var rttWindow: [Double] = []

    /// Handshake finished; the SAS is ready to show. Main queue.
    var onPaired: (() -> Void)?
    /// Host accepted; the session is live. Main queue.
    var onAccepted: (() -> Void)?
    /// A decoded op arrived. Main queue.
    var onOp: ((Inbound) -> Void)?
    /// Connection failed or closed. Main queue.
    var onClosed: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "beam.session", qos: .userInteractive)
    private let localName: String
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private var sendKey: SymmetricKey?
    private var recvKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    private var pingTimer: DispatchSourceTimer?
    private var closed = false

    private static let magic: [UInt8] = [0x42, 0x45, 0x41, 0x4d]  // "BEAM"
    private static let version: UInt8 = 1

    /// Guest side: dial a discovered peer.
    convenience init(connectingTo endpoint: NWEndpoint, localName: String) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // §4.6: Nagle + delayed ACK produce 40 ms+ spikes. Every socket, always.
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        self.init(connection: NWConnection(to: endpoint, using: params),
                  role: .initiator, localName: localName)
    }

    /// Host side: an inbound connection from the listener.
    convenience init(accepting connection: NWConnection, localName: String) {
        (connection.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        self.init(connection: connection, role: .responder, localName: localName)
    }

    private init(connection: NWConnection, role: Role, localName: String) {
        self.connection = connection
        self.role = role
        self.localName = localName
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendHandshake()
            case .failed(let e): self.close(reason: "connection failed: \(e)")
            case .cancelled: self.close(reason: nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        pingTimer?.cancel()
        connection.cancel()
    }

    // MARK: - Handshake

    private func sendHandshake() {
        var out = Self.magic
        out.append(Self.version)
        out.append(contentsOf: privateKey.publicKey.rawRepresentation)
        let name = Array(localName.utf8.prefix(64))
        out.append(UInt8(name.count))
        out.append(contentsOf: name)
        connection.send(content: Data(out), completion: .idempotent)
        bytesSent += out.count
        readHandshake()
    }

    private func readHandshake() {
        // Fixed 38-byte prefix (magic + version + key + name length), then the name.
        receiveExactly(38) { [weak self] head in
            guard let self else { return }
            guard Array(head[0..<4]) == Self.magic, head[4] == Self.version else {
                self.close(reason: "not a Beam peer")
                return
            }
            let nameLen = Int(head[37])
            let finish: ([UInt8]) -> Void = { nameBytes in
                self.peerName = String(decoding: nameBytes, as: UTF8.self)
                self.deriveKeys(peerPublicKey: Array(head[5..<37]))
            }
            if nameLen == 0 { finish([]) } else { self.receiveExactly(nameLen, then: finish) }
        }
    }

    private func deriveKeys(peerPublicKey: [UInt8]) {
        if Sabotage.joinDelayMs > 0 {
            // Before the agreement, not after: a slow handshake must delay the
            // moment the code can be SHOWN, which is what the join gates
            // measure. Sleeping after the SAS is published would prove nothing.
            Thread.sleep(forTimeInterval: Double(Sabotage.joinDelayMs) / 1000)
        }
        let t0 = monotonicNow()
        guard let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: theirKey) else {
            close(reason: "key agreement failed")
            return
        }
        // Salt binds both public keys AND their roles, so the two sides derive
        // an identical SAS while an interposed attacker cannot.
        let mine = Array(privateKey.publicKey.rawRepresentation)
        let salt = role == .initiator ? mine + peerPublicKey : peerPublicKey + mine

        let traffic = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(salt),
            sharedInfo: Data("beam-session-v1".utf8), outputByteCount: 64)
        let halves = traffic.withUnsafeBytes { Array($0) }
        let initiatorKey = SymmetricKey(data: halves[0..<32])
        let responderKey = SymmetricKey(data: halves[32..<64])
        sendKey = role == .initiator ? initiatorKey : responderKey
        recvKey = role == .initiator ? responderKey : initiatorKey

        let sasKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(salt),
            sharedInfo: Data("beam-sas-v1".utf8), outputByteCount: 4)
        let sasBytes = sasKey.withUnsafeBytes { Array($0) }
        var n: UInt32 = 0
        for b in sasBytes { n = (n << 8) | UInt32(b) }
        sas = String(format: "%06u", n % 1_000_000)
        cryptoCpuMs = (monotonicNow() - t0) * 1000

        readFrame()
        DispatchQueue.main.async { self.onPaired?() }
    }

    // MARK: - Encrypted frames

    func send(_ op: Op, _ payload: [UInt8] = []) {
        queue.async { [weak self] in self?.sendOnQueue(op, payload) }
    }

    private func sendOnQueue(_ op: Op, _ payload: [UInt8]) {
        guard let key = sendKey, !closed else { return }
        var plain = [op.rawValue]
        plain.append(contentsOf: payload)
        let nonce = Self.nonce(sendCounter)
        sendCounter &+= 1
        guard let sealed = try? ChaChaPoly.seal(plain, using: key, nonce: nonce) else { return }
        let body = sealed.ciphertext + sealed.tag
        var frame = [UInt8]()
        frame.reserveCapacity(4 + body.count)
        let len = UInt32(body.count)
        frame.append(contentsOf: [UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff),
                                  UInt8(len >> 8 & 0xff), UInt8(len & 0xff)])
        frame.append(contentsOf: body)
        bytesSent += frame.count
        connection.send(content: Data(frame), completion: .idempotent)
    }

    private func readFrame() {
        receiveExactly(4) { [weak self] head in
            guard let self else { return }
            let len = (Int(head[0]) << 24) | (Int(head[1]) << 16) | (Int(head[2]) << 8) | Int(head[3])
            guard len > 16, len < 1 << 20 else { self.close(reason: "bad frame length"); return }
            self.receiveExactly(len) { body in
                self.decode(body)
                self.readFrame()
            }
        }
    }

    private func decode(_ body: [UInt8]) {
        guard let key = recvKey else { return }
        let nonce = Self.nonce(recvCounter)
        recvCounter &+= 1
        guard let box = try? ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: body[0..<(body.count - 16)], tag: body[(body.count - 16)...]),
              let plain = try? ChaChaPoly.open(box, using: key), let type = plain.first,
              let op = Op(rawValue: type) else {
            // A counter mismatch or a forged frame — both mean this session is
            // no longer trustworthy. Never try to resynchronise.
            close(reason: "decryption failed")
            return
        }
        let payload = Array(plain.dropFirst())
        switch op {
        case .ping:
            sendOnQueue(.pong, payload)   // echo the sender's own clock back
            return
        case .pong:
            let sent = Self.readDouble(payload, 0)
            let rtt = (monotonicNow() - sent) * 1000
            DispatchQueue.main.async {
                self.rttWindow.append(rtt)
                if self.rttWindow.count > 8 { self.rttWindow.removeFirst() }
                self.onOp?(Inbound(op: .pong, bytes: payload, t0: sent))
            }
            return
        case .accept:
            // Only the side that ASKED to join can be let in by the other. The
            // host's return keypress is the entire authorization in this
            // scheme, so a host must never be moved into a session by a frame
            // arriving on the wire — otherwise a guest could simply send
            // `accept` and join itself.
            guard role == .initiator else {
                close(reason: "peer tried to accept its own join request")
                return
            }
            DispatchQueue.main.async { self.onAccepted?() }
            return
        default: break
        }
        DispatchQueue.main.async { self.onOp?(Inbound(op: op, bytes: payload, t0: 0)) }
    }

    /// 2 Hz RTT probe. Slow enough that connected idle CPU stays inside its
    /// budget (the gate that makes showing live RTT honest), fast enough that
    /// a Wi-Fi power-save spike shows up while you are still looking.
    func startRTTProbe() {
        if ProcessInfo.processInfo.environment["BEAM_NO_RTT"] == "1" { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendOnQueue(.ping, Self.doubleBytes(monotonicNow()))
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Plumbing

    private func receiveExactly(_ n: Int, then done: @escaping ([UInt8]) -> Void) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.close(reason: "receive failed: \(error)"); return }
            guard let data, data.count == n else {
                if isComplete { self.close(reason: nil) }
                return
            }
            done(Array(data))
        }
    }

    private func close(reason: String?) {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        connection.cancel()
        DispatchQueue.main.async { self.onClosed?(reason) }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var raw = [UInt8](repeating: 0, count: 12)
        var c = counter
        for i in 0..<8 { raw[4 + i] = UInt8(truncatingIfNeeded: c); c >>= 8 }
        return try! ChaChaPoly.Nonce(data: raw)
    }

    static func doubleBytes(_ v: Double) -> [UInt8] {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) }
    }

    static func readDouble(_ bytes: [UInt8], _ offset: Int) -> Double {
        guard bytes.count >= offset + 8 else { return 0 }
        var raw: UInt64 = 0
        for i in (0..<8).reversed() { raw = (raw << 8) | UInt64(bytes[offset + i]) }
        return Double(bitPattern: raw)
    }

    static func u16Bytes(_ v: Int) -> [UInt8] {
        let u = UInt16(truncatingIfNeeded: v)
        return [UInt8(u >> 8), UInt8(u & 0xff)]
    }

    static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard bytes.count >= offset + 2 else { return 0 }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }
}
