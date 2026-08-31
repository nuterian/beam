import AppKit
import Foundation
import Darwin
import BeamCore

/// L5/L6/L7 join bench: two real Beam processes on one machine, finding each
/// other over Bonjour and pairing over loopback TCP through exactly the code
/// path a user's gesture drives. Nothing is stubbed — real NWBrowser, real
/// X25519, real ChaChaPoly, real synthesized keystroke through
/// `window.sendEvent`, and every "visible" mark is a `presentedTime`, never a
/// model callback.
///
/// Roles: `--role host` advertises, prints `BEAM_HOST_READY`, auto-confirms the
/// six digits the instant they are on ITS glass, and reports its own clock
/// marks back over the encrypted channel. `--role guest` cold-launches into a
/// network that already has a peer, makes the gesture, and does all the
/// arithmetic and all the writing.
///
/// Clock domain: one machine, so host and guest timestamps are the same mach
/// uptime clock and subtract directly. That is *why* the cross-machine rig rows
/// still use RTT decomposition (PLAN.md §3.1) — this shortcut does not travel.
///
/// Window layout is left/right and non-overlapping on purpose: WindowServer
/// drops every present from an occluded window, so two stacked windows would
/// have measured fiction.
final class JoinBench {
    private enum Mark: UInt8 {
        case codePresented = 1   // a = host's presentedTime of the code frame
        case confirmed = 2       // a = host's uptime when it confirmed
        case remotePresented = 3 // a = guest's keystroke t0, b = host's presentedTime
        case stats = 4           // a = host crypto ms, b = host idle CPU %
        case quietStart = 5      // begin the shared idle-CPU window
    }

    private let view: GridView
    private let window: NSWindow
    private let app: AppModel
    private let role: JoinRole
    private let outPath: String

    /// Paced keystrokes for the loopback E2E distribution, after the headline
    /// first-keystroke measurement.
    private let e2eKeys = 120
    private let e2eGapMs = 23.0
    private let quietSeconds = Double(ProcessInfo.processInfo.environment["BEAM_QUIET_SECONDS"] ?? "") ?? 3.0

    private var hostProcess: Process?
    private var watchdog: Timer?
    private var lastProgress = monotonicNow()
    private var activity: NSObjectProtocol?
    private var stage = "starting"

    // Guest-side accumulators.
    private var launchToPeersMs: Double?
    private var gestureAt: Double?
    private var guestCodeAt: Double?
    private var hostCodeAt: Double?
    private var hostConfirmAt: Double?
    private var guestEditorAt: Double?
    private var firstSharedKeyPresentedAt: Double?
    private var e2eSamples: [Double] = []
    private var bytesAtStart = 0
    private var bytesPerKeystroke: Double?
    private var hostCryptoMs: Double?
    private var hostIdleCPU: Double?
    private var guestIdleCPU: Double?
    private var sentKeys = 0

    init(view: GridView, window: NSWindow, app: AppModel, role: JoinRole, outPath: String) {
        self.view = view
        self.window = window
        self.app = app
        self.role = role
        self.outPath = outPath
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .idleDisplaySleepDisabled], reason: "beam join bench")
        app.startDiscovery()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
        switch role {
        case .host: startHost()
        case .guest: startGuest()
        }
    }

    // MARK: - Host

    private func startHost() {
        stage = "advertising"
        app.onPairingReady = { [weak self] in self?.progress("paired") }
        // Confirm the moment the code is on OUR glass — the bench stands in for
        // the human, and the human cannot compare digits they have not seen.
        view.onCodePresented = { [weak self] presented in
            guard let self, self.stage != "confirmed" else { return }
            self.stage = "confirmed"
            self.progress("code presented")
            self.app.session?.send(.benchMark, [Mark.codePresented.rawValue] + Session.doubleBytes(presented))
            let confirmAt = monotonicNow()
            self.app.confirmJoin()
            self.app.session?.send(.benchMark, [Mark.confirmed.rawValue] + Session.doubleBytes(confirmAt))
        }
        // Every frame carrying a guest keystroke reports itself back.
        view.onRemotePresented = { [weak self] t0, presented in
            guard let self else { return }
            self.progress("remote key")
            self.app.session?.send(.benchMark,
                [Mark.remotePresented.rawValue] + Session.doubleBytes(t0) + Session.doubleBytes(presented))
        }
        app.onSessionOp = { [weak self] inbound in
            guard let self, inbound.op == .benchMark, let kind = inbound.bytes.first else { return }
            switch Mark(rawValue: kind) {
            case .quietStart:
                // Both sides must measure the SAME window. Starting ours when
                // editing began would have charged the host for all 120
                // keystrokes and reported it as idle.
                self.markQuietStart()
            case .stats:
                let cpu = self.cpuSinceQuietStart()
                self.app.session?.send(.benchMark, [Mark.stats.rawValue]
                    + Session.doubleBytes(self.app.session?.cryptoCpuMs ?? 0) + Session.doubleBytes(cpu))
            default: break
            }
        }
        // Readiness sentinel: bench.sh waits for this before cold-launching the
        // guest, so the guest's launch_to_peers_visible number is honest — a
        // peer is already on the network when it starts, and the guest is never
        // charged for our startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            FileHandle.standardError.write("BEAM_HOST_READY\n".data(using: .utf8)!)
        }
    }

    // MARK: - Guest

    private func startGuest() {
        stage = "discovering"
        view.onPeersPresented = { [weak self] presented in
            guard let self, self.launchToPeersMs == nil else { return }
            self.launchToPeersMs = (presented - processStartUptime()) * 1000
            self.progress("peers visible")
            // The peer is on the glass — make the gesture on the next runloop
            // turn so this frame is fully accounted before the next begins.
            DispatchQueue.main.async { self.makeGesture() }
        }
        view.onCodePresented = { [weak self] presented in
            guard let self, self.guestCodeAt == nil else { return }
            self.guestCodeAt = presented
            self.progress("code visible")
        }
        view.onEditorPresented = { [weak self] presented in
            guard let self, self.guestEditorAt == nil else { return }
            self.guestEditorAt = presented
            self.progress("editing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.sendFirstSharedKey() }
        }
        app.onSessionOp = { [weak self] inbound in self?.hostMark(inbound) }
    }

    /// The gesture itself: real key events through the real window event path,
    /// exactly as `--bench-typing` does.
    ///
    /// **What "the gesture" is, after PLAN.md §5.3.** §5.1's whole join UI was
    /// "a number or a click" on a roster that was the launch screen. Beam now
    /// launches into a document, so reaching the peer list is `⌘K` and choosing
    /// a peer is still its number. The metric starts at the **number**, not at
    /// `⌘K`: opening a list is navigation, and the time a human spends looking
    /// at it is not ours to budget — the same argument the auto-confirm in
    /// `join_gesture_to_first_shared_keystroke_ms` already makes. From the
    /// instant you commit to a peer, every millisecond is still counted.
    private func makeGesture() {
        guard gestureAt == nil else { return }
        // Browse results can momentarily go empty as Bonjour republishes; the
        // gesture is only meaningful with a peer actually discovered.
        guard !app.peers.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.makeGesture() }
            return
        }
        stage = "joining"
        send(characters: "k", keyCode: 40, command: true)   // ⌘K — open the peer list
        guard app.overlay == .peers, !app.overlayItems.isEmpty else {
            fail("⌘K did not open a peer list (overlay=\(String(describing: app.overlay)), items=\(app.overlayItems.count))")
        }
        progress("peer list open")
        // Next runloop turn, so the number is a separate event with its own
        // timestamp and the measurement starts exactly where it says it does.
        DispatchQueue.main.async {
            let t = ProcessInfo.processInfo.systemUptime
            self.gestureAt = t
            self.send(characters: "1", keyCode: 18, timestamp: t)
            self.progress("gesture sent")
        }
    }

    private func send(characters: String, keyCode: UInt16, command: Bool = false,
                      timestamp: Double? = nil) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
            timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { fail("cannot synthesize a key event") }
        window.sendEvent(event)
    }

    private func hostMark(_ inbound: Session.Inbound) {
        guard inbound.op == .benchMark, let kind = inbound.bytes.first,
              let mark = Mark(rawValue: kind) else { return }
        let a = Session.readDouble(inbound.bytes, 1)
        let b = Session.readDouble(inbound.bytes, 9)
        switch mark {
        case .codePresented:
            hostCodeAt = a
            progress("host code")
        case .confirmed:
            hostConfirmAt = a
            progress("host confirmed")
        case .remotePresented:
            if firstSharedKeyPresentedAt == nil {
                firstSharedKeyPresentedAt = b
                progress("first shared keystroke")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.runE2EPass() }
            } else {
                e2eSamples.append((b - a) * 1000)
                progress("e2e sample")
            }
        case .stats:
            hostCryptoMs = a
            hostIdleCPU = b
            finish()
        case .quietStart:
            break  // host-side only
        }
    }

    private func sendFirstSharedKey() {
        guard firstSharedKeyPresentedAt == nil else { return }
        stage = "first shared keystroke"
        sendKey()
    }

    /// A short paced pass so the loopback E2E row has a distribution rather
    /// than a single sample. 23 ms is co-prime with the frame interval, so the
    /// keystrokes sweep vsync phase uniformly (same reasoning as the L2 bench).
    private func runE2EPass() {
        stage = "e2e pass"
        bytesAtStart = app.session?.bytesSentSync() ?? 0
        var left = e2eKeys
        func step() {
            if left == 0 {
                let sent = (app.session?.bytesSentSync() ?? 0) - bytesAtStart
                bytesPerKeystroke = Double(sent) / Double(e2eKeys)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.beginQuietWindow() }
                return
            }
            left -= 1
            sendKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + e2eGapMs / 1000) { step() }
        }
        step()
    }

    /// Connected-and-quiet: an established encrypted session with a 2 Hz RTT
    /// probe on each side and nothing else happening. This is the gate that
    /// makes live RTT in the HUD honest (PLAN.md §5.1).
    private func beginQuietWindow() {
        stage = "quiet window"
        app.session?.send(.benchMark, [Mark.quietStart.rawValue])
        markQuietStart()
        progress("quiet")
        DispatchQueue.main.asyncAfter(deadline: .now() + quietSeconds) { [weak self] in
            guard let self else { return }
            self.guestIdleCPU = self.cpuSinceQuietStart()
            FileHandle.standardError.write(String(format:
                "quiet window: %d renders, %d display-link ticks over %.1f s\n",
                self.view.renderCount - self.quietRenders,
                self.view.tickCount - self.quietTicks,
                monotonicNow() - self.quietWallStart).data(using: .utf8)!)
            self.progress("quiet done")
            self.app.session?.send(.benchMark, [Mark.stats.rawValue])
        }
    }

    // MARK: - Plumbing

    private var quietCPUStart: Double = 0
    private var quietWallStart: Double = 0

    private var quietRenders = 0
    private var quietTicks = 0

    private func markQuietStart() {
        quietCPUStart = processCPUSeconds()
        quietWallStart = monotonicNow()
        quietRenders = view.renderCount
        quietTicks = view.tickCount
    }

    private func cpuSinceQuietStart() -> Double {
        let wall = monotonicNow() - quietWallStart
        guard wall > 0.5 else { return 0 }
        return (processCPUSeconds() - quietCPUStart) / wall * 100
    }

    private func sendKey() {
        sentKeys += 1
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789 "
        let c = Array(chars)[sentKeys % chars.count]
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: String(c), charactersIgnoringModifiers: String(c),
            isARepeat: false, keyCode: 0
        ) else { fail("cannot synthesize key event") }
        window.sendEvent(event)
    }

    private func progress(_ s: String) {
        lastProgress = monotonicNow()
        if ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1" {
            FileHandle.standardError.write("[\(role.rawValue)] \(s)\n".data(using: .utf8)!)
        }
    }

    private func checkWatchdog() {
        guard monotonicNow() - lastProgress > 12 else { return }
        if role == .host { exit(0) }  // guest gone or never came; nothing to report
        fail("stalled at stage '\(stage)' — no progress for 12 s")
    }

    private func fail(_ why: String) -> Never {
        FileHandle.standardError.write(
            "join bench FAILED: \(why) (peers=\(app.peers.count), session=\(app.session != nil), delivered=\(e2eSamples.count))\n"
                .data(using: .utf8)!)
        exit(4)
    }

    // MARK: - Results

    private func finish() {
        watchdog?.invalidate()
        // Validity, by ground truth rather than by proxy: every number this
        // bench publishes came from a `presentedTime > 0` on one side or the
        // other, and the host reports one per keystroke it actually put on the
        // glass. If the two windows were not really on screen, WindowServer
        // drops those presents and the reports never arrive — so a healthy
        // delivery ratio IS the visibility check, and a strictly stronger one
        // than NSWindow.occlusionState (which never reports visible at all for
        // whichever of the two processes is not the active app).
        // Not 1.0: keystrokes are paced at 23 ms, slower than a frame, but the
        // render loop still coalesces any that share a frame and reports the
        // OLDEST t0 for it (same worst-case-honest accounting as the L2 burst
        // pass). Coalescing therefore under-counts reports while biasing the
        // latency it does report *upward*, which is the safe direction. What
        // this threshold is actually for is the failure that matters —
        // wholesale present drops from a window that is not on the glass, which
        // takes delivery to zero, not to 80%.
        let delivered = e2eSamples.count + (firstSharedKeyPresentedAt != nil ? 1 : 0)
        let ratio = Double(delivered) / Double(e2eKeys + 1)
        if ratio < 0.75 {
            FileHandle.standardError.write(String(format:
                "join bench INVALID: only %d of %d keystrokes reached the peer's glass (%.0f%%). Presents are being dropped — the bench windows must be visible and unobstructed (they float on all Spaces); an occluded screen or screensaver drops every present.\n",
                delivered, e2eKeys + 1, ratio * 100).data(using: .utf8)!)
            exit(5)
        }
        guard let gesture = gestureAt, let guestCode = guestCodeAt, let hostCode = hostCodeAt,
              let confirm = hostConfirmAt, let editor = guestEditorAt,
              let firstKey = firstSharedKeyPresentedAt, let peers = launchToPeersMs,
              let bytes = bytesPerKeystroke, !e2eSamples.isEmpty else {
            FileHandle.standardError.write(
                "join bench: incomplete run (peers=\(launchToPeersMs != nil) gesture=\(gestureAt != nil) guestCode=\(guestCodeAt != nil) hostCode=\(hostCodeAt != nil) confirm=\(hostConfirmAt != nil) editor=\(guestEditorAt != nil) firstKey=\(firstSharedKeyPresentedAt != nil) e2e=\(e2eSamples.count))\n"
                    .data(using: .utf8)!)
            exit(4)
        }

        // Both screens must show the code before a human can compare them, so
        // the later of the two presents is the honest number.
        let codeVisibleMs = (max(guestCode, hostCode) - gesture) * 1000
        let confirmToEditingMs = (editor - confirm) * 1000
        let headlineMs = (firstKey - gesture) * 1000
        let e2e = summarize(e2eSamples)
        let cryptoMs = max(app.session?.cryptoCpuMs ?? 0, hostCryptoMs ?? 0)
        let idleCPU = max(guestIdleCPU ?? 0, hostIdleCPU ?? 0)

        print(String(format: "launch -> peer row presented:        %.1f ms", peers))
        print(String(format: "gesture -> code on BOTH screens:     %.1f ms (guest %.1f, host %.1f)",
                     codeVisibleMs, (guestCode - gesture) * 1000, (hostCode - gesture) * 1000))
        print(String(format: "host confirm -> guest editing:       %.1f ms", confirmToEditingMs))
        print(String(format: "gesture -> first shared keystroke:   %.1f ms", headlineMs))
        print(String(format: "keystroke -> remote presented n=%d: p50 %.2f  p95 %.2f  p99 %.2f  max %.2f ms",
                     e2eSamples.count, e2e.p50, e2e.p95, e2e.p99, e2e.max))
        // Informational only, and deliberately higher than the gated counter:
        // this figure includes the RTT probe and the bench's own mark frames
        // sharing the socket. The deterministic number comes from
        // --verify-session, which has neither.
        print(String(format: "bytes/keystroke on wire:             %.1f (incl. RTT probe; gated counter is --verify-session)", bytes))
        print(String(format: "handshake crypto:                    %.3f ms", cryptoMs))
        print(String(format: "connected idle CPU (worse of two):   %.3f%% core  (guest %.3f, host %.3f)",
                     idleCPU, guestIdleCPU ?? 0, hostIdleCPU ?? 0))

        do {
            try writeResult(to: outPath, metrics: [
                "L1_lifecycle.launch_to_peers_visible_ms": peers,
                "L5_presence_session.join_gesture_to_code_visible_ms": codeVisibleMs,
                "L5_presence_session.join_confirm_to_editing_ms": confirmToEditingMs,
                "L5_presence_session.join_gesture_to_first_shared_keystroke_ms": headlineMs,
                "L5_presence_session.handshake_crypto_cpu_ms": cryptoMs,
                "L6_end_to_end.keystroke_to_remote_present_loopback_p99_ms": e2e.p99,
                "L7_steady_state.idle_cpu_connected_pct_core": idleCPU,
            ])
        } catch {
            FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
        exit(0)
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + sys
    }
}
