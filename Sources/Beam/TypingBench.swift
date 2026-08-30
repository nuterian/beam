import AppKit
import Foundation
import Darwin
import BeamCore

/// L2 typing bench, four passes through the real window event path
/// (window.sendEvent -> first responder -> model -> Metal present):
///
///   paced   n keystrokes at 23 ms — slower than a frame (presents drain, no
///           back-pressure) and co-prime with 16.7/8.3 ms so keystrokes sweep
///           vsync phases uniformly. Yields p50/p99, plus two novel gates:
///           MIN latency (present-pipeline depth — how fast the luckiest
///           keystroke can possibly appear) and SPREAD p99-p50 (jitter; the
///           tail is the UX, PLAN.md §3.1).
///   burst   150 keystrokes at 8 ms — faster than any key-repeat. Catches
///           coalescing pathologies and drawable back-pressure stalls.
///   idle    10 single keystrokes, each after 2 s of idle — the cold-pipeline
///           tax on the FIRST keystroke, which is the one users feel.
///   alloc   malloc deltas across the paced window -> bytes per keystroke.
///
/// t0 is the synthetic event's timestamp, set at creation — the software path
/// after that is identical to real typing; only pre-queue IOHID transit is
/// missing, which the camera calibration (PLAN.md §3.1) accounts for.
final class TypingBench {
    private let view: GridView
    private let window: NSWindow
    private let outPath: String
    private let warmup = 50
    private let n: Int
    private let burstCount = 150
    private let idleReps = 10

    private var sent = 0
    private var lastProgress = monotonicNow()
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?

    private var pacedCommit: [Double] = []
    private var pacedPresented: [Double] = []
    private var burstPresented: [Double] = []
    private var idlePresented: [Double] = []
    private var mallocBytesPerKey = 0.0
    private var mallocBlocksPerKey = 0.0

    init(view: GridView, window: NSWindow, n: Int, outPath: String) {
        self.view = view
        self.window = window
        self.n = n
        self.outPath = outPath
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .idleDisplaySleepDisabled],
            reason: "beam typing bench")
        view.recorder.collectAll = true
        view.recorder.onPresentedSample = { [weak self] _ in
            self?.lastProgress = monotonicNow()
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if monotonicNow() - self.lastProgress > 6 {
                FileHandle.standardError.write("typing bench stalled (no presented frames for 6s)\n".data(using: .utf8)!)
                exit(4)
            }
        }
        runKeys(count: warmup, gapMs: 23) { [weak self] in self?.beginPaced() }
    }

    // MARK: - Passes

    private func beginPaced() {
        view.recorder.reset()
        let statsBefore = mallocSnapshot()
        runKeys(count: n, gapMs: 23) { [weak self] in
            guard let self else { return }
            self.drain {
                let statsAfter = self.mallocSnapshot()
                self.mallocBytesPerKey = Double(statsAfter.bytes - statsBefore.bytes) / Double(self.n)
                self.mallocBlocksPerKey = Double(statsAfter.blocks - statsBefore.blocks) / Double(self.n)
                self.pacedCommit = self.view.recorder.commitSamples
                self.pacedPresented = self.view.recorder.presentedSamples
                self.beginBurst()
            }
        }
    }

    private func beginBurst() {
        view.recorder.reset()
        runKeys(count: burstCount, gapMs: 8) { [weak self] in
            guard let self else { return }
            self.drain {
                self.burstPresented = self.view.recorder.presentedSamples
                self.beginIdleSingles()
            }
        }
    }

    private func beginIdleSingles() {
        view.recorder.reset()
        idleStep(remaining: idleReps)
    }

    private func idleStep(remaining: Int) {
        if remaining == 0 {
            idlePresented = view.recorder.presentedSamples
            finish()
            return
        }
        lastProgress = monotonicNow()  // keep the watchdog calm across the idle gap
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.sendKey()
            // Give the present ample time, then continue regardless (a dropped
            // present would otherwise hang the pass; the sample count reveals it).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.idleStep(remaining: remaining - 1)
            }
        }
    }

    // MARK: - Plumbing

    private func runKeys(count: Int, gapMs: Double, then done: @escaping () -> Void) {
        var left = count
        func step() {
            if left == 0 { done(); return }
            left -= 1
            self.sendKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + gapMs / 1000) { step() }
        }
        step()
    }

    /// Wait for in-flight presents to land before reading sample arrays.
    private func drain(_ done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
    }

    private var sawOcclusion = false

    private func sendKey() {
        if !window.occlusionState.contains(.visible) { sawOcclusion = true }
        sent += 1
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789 "
        let c = Array(chars)[sent % chars.count]
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: String(c), charactersIgnoringModifiers: String(c),
            isARepeat: false, keyCode: 0
        ) else {
            FileHandle.standardError.write("cannot synthesize key event\n".data(using: .utf8)!)
            exit(4)
        }
        window.sendEvent(event)
    }

    private func mallocSnapshot() -> (bytes: Int, blocks: Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (bytes: Int(stats.size_in_use), blocks: Int(stats.blocks_in_use))
    }

    // MARK: - Results

    private func finish() {
        watchdog?.invalidate()
        if sawOcclusion {
            // Latency numbers from an occluded window are fiction (presents
            // drop). Refuse to publish rather than gate on garbage.
            FileHandle.standardError.write(
                "typing bench INVALID: window was occluded during the run — keep the Beam window visible (it floats on all Spaces) and re-run\n"
                    .data(using: .utf8)!)
            exit(5)
        }
        guard !pacedPresented.isEmpty, !burstPresented.isEmpty, !idlePresented.isEmpty else {
            FileHandle.standardError.write(
                "typing bench: empty pass (paced=\(pacedPresented.count) burst=\(burstPresented.count) idle=\(idlePresented.count))\n"
                    .data(using: .utf8)!)
            exit(4)
        }
        let commit = summarize(pacedCommit)
        let presented = summarize(pacedPresented)
        let presentedMin = pacedPresented.min()!
        let spread = presented.p99 - presented.p50
        let burst = summarize(burstPresented)
        let idle = summarize(idlePresented)
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        let suffix = fps >= 100 ? "120hz" : "60hz"
        let mode = Renderer.presentMode.rawValue

        func line(_ label: String, _ s: [Double]) {
            let p = summarize(s)
            print(String(format: "%@ n=%d: p50 %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f ms",
                         label, s.count, p.p50, p.p95, p.p99, p.p999, p.max))
        }
        print("present mode: \(mode), \(fps) Hz panel")
        line("keystroke -> commit    ", pacedCommit)
        line("keystroke -> presented ", pacedPresented)
        print(String(format: "presented min %.2f ms (pipeline depth)   spread p99-p50 %.2f ms (jitter)", presentedMin, spread))
        line("burst @125Hz presented ", burstPresented)
        line("first key after idle   ", idlePresented)
        print(String(format: "malloc per keystroke: %.0f bytes, %.1f blocks", mallocBytesPerKey, mallocBlocksPerKey))
        print("draw calls per frame: \(view.renderer.drawCallsLastFrame)")

        do {
            try writeResult(to: outPath, metrics: [
                "L2_local_render.keystroke_to_commit_p50_ms": commit.p50,
                "L2_local_render.keystroke_to_commit_p99_ms": commit.p99,
                "L2_local_render.keystroke_to_presented_\(suffix)_p50_ms": presented.p50,
                "L2_local_render.keystroke_to_presented_\(suffix)_p99_ms": presented.p99,
                "L2_local_render.keystroke_to_presented_\(suffix)_min_ms": presentedMin,
                "L2_local_render.presented_spread_p99_minus_p50_\(suffix)_ms": spread,
                "L2_local_render.burst_125hz_presented_p99_\(suffix)_ms": burst.p99,
                "L2_local_render.first_keystroke_after_idle_p50_ms": idle.p50,
                "L2_local_render.first_keystroke_after_idle_max_ms": idle.max,
                "L2_local_render.malloc_bytes_per_keystroke": mallocBytesPerKey,
                "L2_local_render.draw_calls_per_frame": Double(view.renderer.drawCallsLastFrame),
            ])
        } catch {
            FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
        exit(0)
    }
}
