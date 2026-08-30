import Foundation
import BeamCore

/// Collects keystroke latency samples. The HUD reads a sliding window; bench
/// mode collects everything. All values are milliseconds. Thread-safety: all
/// mutation happens on the main queue (present/commit callbacks hop there).
final class LatencyRecorder {
    private(set) var commitSamples: [Double] = []      // keystroke -> commit()
    private(set) var presentedSamples: [Double] = []   // keystroke -> photon-adjacent presentedTime
    private let hudWindow = 200

    /// Bench hook: fired after each presented sample is recorded.
    var onPresentedSample: ((Double) -> Void)?

    func recordCommit(_ ms: Double) {
        commitSamples.append(ms)
        trimIfInteractive(&commitSamples)
    }

    func recordPresented(_ ms: Double) {
        presentedSamples.append(ms)
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
    }

    /// (p50, p99) of keystroke->presented over the HUD window, if any samples.
    func hudPresentedStats() -> (p50: Double, p99: Double)? {
        guard !presentedSamples.isEmpty else { return nil }
        let window = Array(presentedSamples.suffix(hudWindow))
        return (percentile(window, 50), percentile(window, 99))
    }
}
