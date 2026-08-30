import AppKit
import Foundation
import BeamCore

/// L2 typing bench: synthesizes keyDown NSEvents into the real window event
/// path (window.sendEvent -> first responder -> model -> Metal present) and
/// records keystroke->commit and keystroke->presented, paced by the presented
/// callback of the previous keystroke so events never coalesce into one frame.
/// t0 is the synthetic event's timestamp, set at creation — the software path
/// after that is identical to real typing; only pre-queue IOHID transit is
/// missing, which the camera calibration (PLAN.md §3.1) accounts for.
final class TypingBench {
    private let view: GridView
    private let window: NSWindow
    private let outPath: String
    private let warmup = 50
    private let n: Int
    private var sent = 0
    private var lastProgress = monotonicNow()
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?

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
            if monotonicNow() - self.lastProgress > 5 {
                FileHandle.standardError.write("typing bench stalled (no presented frames for 5s)\n".data(using: .utf8)!)
                exit(4)
            }
        }
        step()
    }

    private func step() {
        if sent == warmup { view.recorder.reset() }
        if sent >= warmup + n {
            // Allow the last presents to drain before summarizing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finish() }
            return
        }
        sent += 1
        // 23 ms pacing: slower than a frame (presents fully drain, no drawable
        // back-pressure) and co-prime with 16.7/8.3 ms so keystrokes sweep all
        // vsync phases uniformly — pacing off the presented callback would
        // phase-lock every sample and hide the true distribution.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.023) { self.step() }
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

    private func finish() {
        watchdog?.invalidate()
        let commit = summarize(view.recorder.commitSamples)
        let presented = summarize(view.recorder.presentedSamples)
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        let suffix = fps >= 100 ? "120hz" : "60hz"

        print(String(format: "keystroke -> commit     n=%d: p50 %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f ms",
                     view.recorder.commitSamples.count, commit.p50, commit.p95, commit.p99, commit.p999, commit.max))
        print(String(format: "keystroke -> presented  n=%d (%d Hz panel): p50 %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f ms",
                     view.recorder.presentedSamples.count, fps, presented.p50, presented.p95, presented.p99, presented.p999, presented.max))
        print("draw calls per frame: \(view.renderer.drawCallsLastFrame)")

        do {
            try writeResult(to: outPath, metrics: [
                "L2_local_render.keystroke_to_commit_p50_ms": commit.p50,
                "L2_local_render.keystroke_to_commit_p99_ms": commit.p99,
                "L2_local_render.keystroke_to_presented_\(suffix)_p50_ms": presented.p50,
                "L2_local_render.keystroke_to_presented_\(suffix)_p99_ms": presented.p99,
                "L2_local_render.draw_calls_per_frame": Double(view.renderer.drawCallsLastFrame),
            ])
        } catch {
            FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
        exit(0)
    }
}
