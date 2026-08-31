import Foundation
import Network
import CryptoKit
import BeamCore

/// Headless verification of the pairing and transport core (`--verify-session`).
///
/// Everything here is screen-independent and exactly reproducible, so it runs
/// in CI on any runner and is the source of the deterministic wire counter.
/// The security properties it checks are the ones PLAN.md §5.1 claims:
///
///   1. Both sides derive the SAME six digits from a real X25519 exchange.
///   2. An interposed third key derives DIFFERENT digits on each leg — this is
///      the machine-in-the-middle detection the whole scheme rests on, so it is
///      asserted rather than assumed.
///   3. Ops survive the ChaChaPoly round trip intact, in order.
///   4. Bytes on the wire per keystroke (L6, deterministic).
enum SessionVerify {
    static func run(outPath: String?) -> Never {
        // Session delivers its callbacks on the main queue, so the checks run
        // on a background thread and main is left free to service them —
        // blocking main here would deadlock the very handshake we are testing.
        DispatchQueue.global().async { verify(outPath: outPath) }
        RunLoop.main.run()
        exit(3)  // unreachable: verify() always exits
    }

    private static func verify(outPath: String?) -> Never {
        var failures: [String] = []

        // --- 1 & 2: SAS agreement, and MITM divergence. ---
        let sasChecks = checkSAS()
        failures.append(contentsOf: sasChecks)

        // --- 3 & 4: a real encrypted session over loopback. ---
        let (ops, bytesPerKey, transportProblems) = checkTransport()
        failures.append(contentsOf: transportProblems)

        print("session verify:")
        print("  SAS agreement + MITM divergence: \(sasChecks.isEmpty ? "ok" : "FAILED")")
        print("  encrypted op round trip:         \(ops) ops intact")
        print(String(format: "  bytes/keystroke on wire:         %.1f", bytesPerKey))

        if let outPath, failures.isEmpty {
            do {
                try writeResult(to: outPath, metrics: [
                    "L6_end_to_end.bytes_per_keystroke_on_wire": bytesPerKey,
                ])
            } catch {
                FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
                exit(4)
            }
        }
        if !failures.isEmpty {
            for f in failures { FileHandle.standardError.write("session verify FAILED: \(f)\n".data(using: .utf8)!) }
            exit(1)
        }
        print("BEAM_SESSION_OK")
        exit(0)
    }

    /// Mirrors Session.deriveKeys exactly. Kept as a separate implementation on
    /// purpose: if the two ever disagree, one of them is wrong and the test is
    /// worth having.
    private static func sas(_ mine: Curve25519.KeyAgreement.PrivateKey,
                            _ theirs: Curve25519.KeyAgreement.PublicKey,
                            initiatorPub: [UInt8], responderPub: [UInt8]) -> String? {
        guard let secret = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(initiatorPub + responderPub),
            sharedInfo: Data("beam-sas-v1".utf8), outputByteCount: 4)
        var n: UInt32 = 0
        for b in key.withUnsafeBytes({ Array($0) }) { n = (n << 8) | UInt32(b) }
        return String(format: "%06u", n % 1_000_000)
    }

    private static func checkSAS() -> [String] {
        var problems: [String] = []
        let guest = Curve25519.KeyAgreement.PrivateKey()
        let host = Curve25519.KeyAgreement.PrivateKey()
        let gPub = Array(guest.publicKey.rawRepresentation)
        let hPub = Array(host.publicKey.rawRepresentation)

        let guestSAS = sas(guest, host.publicKey, initiatorPub: gPub, responderPub: hPub)
        let hostSAS = sas(host, guest.publicKey, initiatorPub: gPub, responderPub: hPub)
        guard let g = guestSAS, let h = hostSAS else { return ["key agreement failed"] }
        if g != h { problems.append("honest peers derived different codes (\(g) vs \(h))") }
        if g.count != 6 || !g.allSatisfy(\.isNumber) { problems.append("code is not six digits: \(g)") }

        // The attack the six digits exist to stop: an attacker who terminates
        // both legs with its own key. Each victim now derives a code against
        // the ATTACKER's key, and the two codes must not match — that mismatch
        // is what the humans see.
        let mitm = Curve25519.KeyAgreement.PrivateKey()
        let mPub = Array(mitm.publicKey.rawRepresentation)
        let guestLeg = sas(guest, mitm.publicKey, initiatorPub: gPub, responderPub: mPub)
        let hostLeg = sas(host, mitm.publicKey, initiatorPub: mPub, responderPub: hPub)
        if guestLeg == nil || hostLeg == nil {
            problems.append("MITM legs failed to derive")
        } else if guestLeg == hostLeg {
            problems.append("MACHINE-IN-THE-MIDDLE NOT DETECTED: both legs derived \(guestLeg!)")
        }
        return problems
    }

    /// A real Session pair over a real loopback socket — same code the app runs.
    private static func checkTransport() -> (Int, Double, [String]) {
        var problems: [String] = []
        let keystrokes = 100
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            return (0, 0, ["cannot create listener"])
        }

        let queue = DispatchQueue(label: "beam.verify")
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var hostSession: Session?
        var guestSession: Session?
        var received: [UInt8] = []
        var hostSAS = "", guestSAS = ""

        listener.newConnectionHandler = { conn in
            let s = Session(accepting: conn, localName: "verify-host")
            s.onPaired = { hostSAS = s.sas }
            s.onOp = { inbound in
                guard inbound.op == .insert, inbound.bytes.count >= 9 else { return }
                received.append(inbound.bytes[8])
                if received.count == keystrokes { done.signal() }
            }
            hostSession = s
            s.start()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            return (0, 0, ["listener never became ready"])
        }

        let paired = DispatchSemaphore(value: 0)
        let guest = Session(connectingTo: .hostPort(host: "127.0.0.1", port: port),
                            localName: "verify-guest")
        guest.onPaired = { guestSAS = guest.sas; paired.signal() }
        guestSession = guest
        guest.start()

        guard paired.wait(timeout: .now() + 5) == .success else {
            return (0, 0, ["handshake never completed over loopback"])
        }
        if guestSAS.isEmpty || guestSAS != hostSAS {
            problems.append("live session codes differ: guest \(guestSAS) vs host \(hostSAS)")
        }

        let before = guest.bytesSentSync()
        var expected: [UInt8] = []
        for i in 0..<keystrokes {
            let c = UInt8(97 + i % 26)
            expected.append(c)
            guest.send(.insert, AppModel.editPayload(t0: monotonicNow(), [c]))
        }
        if done.wait(timeout: .now() + 10) != .success {
            problems.append("only \(received.count)/\(keystrokes) ops arrived")
        }
        if received != expected {
            problems.append("ops did not survive the round trip intact")
        }
        let bytesPerKey = Double(guest.bytesSentSync() - before) / Double(keystrokes)

        guestSession?.cancel()
        hostSession?.cancel()
        listener.cancel()
        return (received.count, bytesPerKey, problems)
    }
}
