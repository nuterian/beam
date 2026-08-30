import Foundation

/// PLAN.md §3.1: report percentiles and max, never the mean.
public struct Percentiles {
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let p999: Double
    public let max: Double
}

public func percentile(_ samples: [Double], _ p: Double) -> Double {
    precondition(!samples.isEmpty, "percentile() called with no samples")
    let sorted = samples.sorted()
    let idx = min(sorted.count - 1, Int((p / 100.0) * Double(sorted.count)))
    return sorted[idx]
}

public func summarize(_ samples: [Double]) -> Percentiles {
    Percentiles(
        p50: percentile(samples, 50),
        p95: percentile(samples, 95),
        p99: percentile(samples, 99),
        p999: percentile(samples, 99.9),
        max: percentile(samples, 100)
    )
}

/// Monotonic now, seconds, in the same domain as NSEvent.timestamp,
/// CACurrentMediaTime and CAMetalDrawable.presentedTime (mach uptime).
public func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}
