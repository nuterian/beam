import Foundation

/// One metric's spec from perf/budgets.json.
public struct MetricSpec {
    public let budget: Double?
    public let gate: Double?
    public let higherIsBetter: Bool
    public let deterministic: Bool
}

/// Loads perf/budgets.json and flattens every group's `metrics` object into
/// dotted keys ("L2_local_render.keystroke_to_commit_p50_ms"), mirroring the
/// predecessor's gate.ts. Both perf-gate and the in-app HUD read this — the
/// budgets file is the single source of truth (PLAN.md §3.2).
public func loadBudgets(path: String) throws -> [String: MetricSpec] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "beam", code: 1, userInfo: [NSLocalizedDescriptionKey: "budgets.json root is not an object"])
    }
    var flat: [String: MetricSpec] = [:]
    for (groupKey, groupAny) in root {
        guard let group = groupAny as? [String: Any],
              let metrics = group["metrics"] as? [String: Any] else { continue }
        for (metricKey, specAny) in metrics {
            guard let spec = specAny as? [String: Any] else { continue }
            flat["\(groupKey).\(metricKey)"] = MetricSpec(
                budget: (spec["budget"] as? NSNumber)?.doubleValue,
                gate: (spec["gate"] as? NSNumber)?.doubleValue,
                higherIsBetter: (spec["direction"] as? String) == "higher_is_better",
                deterministic: (spec["deterministic"] as? Bool) ?? false
            )
        }
    }
    return flat
}

/// Standard search: $BEAM_BUDGETS_PATH, then ./perf/budgets.json.
public func defaultBudgetsPath() -> String {
    ProcessInfo.processInfo.environment["BEAM_BUDGETS_PATH"] ?? "perf/budgets.json"
}
