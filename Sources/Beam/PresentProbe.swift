import AppKit
import CoreGraphics
import BeamCore

/// Diagnostic mode (--probe-presents): renders at a steady cadence and logs
/// each present's outcome plus window visibility, to characterize when the
/// compositor accepts vs. drops one of our presents. Not a benchmark — a
/// microscope for the present path.
final class PresentProbe {
    private let view: GridView
    private let window: NSWindow
    private var timer: Timer?
    private var n = 0
    private var ok = 0
    private var dropped = 0
    private var phase = 0

    init(view: GridView, window: NSWindow) {
        self.view = view
        self.window = window
    }

    func start() {
        // Three phases: steady 60 Hz for 5 s, quiet for 3 s, then one-shot
        // presents every 2 s. Logs transitions.
        log("phase A: steady ~60 Hz for 5 s")
        var lastReport = monotonicNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = monotonicNow()
            switch self.phase {
            case 0:
                self.probeRender()
                if now - lastReport > 5 { self.phase = 1; lastReport = now; self.report("A"); self.log("phase B: quiet 3 s") }
            case 1:
                if now - lastReport > 3 { self.phase = 2; lastReport = now; self.ok = 0; self.dropped = 0; self.log("phase C: one-shot every 2 s") }
            default:
                if now - lastReport > 2 {
                    lastReport = now
                    self.probeRender()
                    self.n += 1
                    if self.n >= 8 { self.report("C"); exit(0) }
                }
            }
        }
    }

    private func probeRender() {
        let vis = window.occlusionState.contains(.visible)
        _ = view.app.doc.insert([UInt8(65 + (ok + dropped) % 26)])
        let t0 = monotonicNow()
        view.render(t0: nil)  // bypass accounting; we watch the raw handler below
        view.onProbePresent = { [weak self] presentedTime in
            guard let self else { return }
            if presentedTime > 0 {
                self.ok += 1
                if self.phase == 2 {
                    self.log(String(format: "one-shot OK  latency %.1f ms vis=%d", (presentedTime - t0) * 1000, vis ? 1 : 0))
                }
            } else {
                self.dropped += 1
                if self.phase == 2 { self.log("one-shot DROP vis=\(vis ? 1 : 0)") }
            }
        }
    }

    private func report(_ label: String) {
        log("phase \(label): ok=\(ok) dropped=\(dropped)")
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("probe: \(s)\n".data(using: .utf8)!)
    }
}
