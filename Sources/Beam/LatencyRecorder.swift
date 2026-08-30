import Foundation
import BeamCore

/// Collects keystroke latency samples. The HUD reads a sliding window; bench
/// mode collects everything. All values are milliseconds. Thread-safety: all
/// mutation happens on the main queue (present/commit callbacks hop there).
final class LatencyRecorder {
    private(set) var commitSamples: [Double] = []      // keystroke -> present handoff complete
    private(set) var presentedSamples: [Double] = []   // keystroke -> photon-adjacent presentedTime
    /// Absolute (t0, presentedTime) pairs, bench mode only — lets analysis
    /// recover vsync phase, pipeline depth (min latency), and spread.
    private(set) var presentedPairs: [(t0: Double, presented: Double)] = []
    /// NSEvent.timestamp -> keyDown-entry transit (real IOHID input only;
    /// synthetic bench events measure ~0 by construction). The segment no
    /// web-stack editor can even see.
    private(set) var queueTransitSamples: [Double] = []
    private let hudWindow = 200

    /// Bench hook: fired after each presented sample is recorded.
    var onPresentedSample: ((Double) -> Void)?

    init() {
        reserve()
    }

    private func reserve() {
        // Pre-reserve so steady-state appends never trigger a growth
        // reallocation inside a measured window (the alloc counter would
        // otherwise charge our own bookkeeping to the hot path).
        commitSamples.reserveCapacity(8192)
        presentedSamples.reserveCapacity(8192)
        presentedPairs.reserveCapacity(8192)
        queueTransitSamples.reserveCapacity(8192)
    }

    func recordCommit(_ ms: Double) {
        commitSamples.append(ms)
        trimIfInteractive(&commitSamples)
    }

    func recordQueueTransit(_ ms: Double) {
        queueTransitSamples.append(ms)
        trimIfInteractive(&queueTransitSamples)
    }

    private var lastRecordedT0 = -1.0

    func recordPresented(t0: Double, presented: Double) {
        // Wake-double-present renders the same keystroke twice; only the
        // first present to land records the sample (t0 is unique per key).
        guard t0 != lastRecordedT0 else { return }
        lastRecordedT0 = t0
        let ms = (presented - t0) * 1000
        presentedSamples.append(ms)
        if collectAll { presentedPairs.append((t0: t0, presented: presented)) }
        trimIfInteractive(&presentedSamples)
        onPresentedSample?(ms)
    }

    var collectAll = false
    private func trimIfInteractive(_ a: inout [Double]) {
        if !collectAll && a.count > hudWindow { a.removeFirst(a.count - hudWindow) }
    }

    func reset() {
        commitSamples.removeAll(keepingCapacity: true)
        presentedSamples.removeAll(keepingCapacity: true)
        presentedPairs.removeAll(keepingCapacity: true)
        queueTransitSamples.removeAll(keepingCapacity: true)
    }

    /// (p50, p99) of keystroke->presented over the HUD window, if any samples.
    func hudPresentedStats() -> (p50: Double, p99: Double)? {
        guard !presentedSamples.isEmpty else { return nil }
        let window = Array(presentedSamples.suffix(hudWindow))
        return (percentile(window, 50), percentile(window, 99))
    }
}
