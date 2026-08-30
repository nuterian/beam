import Foundation

/// Writes one benchmark's metrics, keyed exactly as they appear in perf/budgets.json
/// (flattened as "Lx_group.metric"), to a JSON file. Benchmarks only measure and emit;
/// perf-gate is the one place that judges. See PLAN.md §3.2.
public func writeResult(to path: String, metrics: [String: Double]) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var lines: [String] = ["{"]
    let keys = metrics.keys.sorted()
    for (i, k) in keys.enumerated() {
        let v = metrics[k]!
        let comma = i == keys.count - 1 ? "" : ","
        lines.append("  \"\(k)\": \(formatNumber(v))\(comma)")
    }
    lines.append("}")
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    print("wrote \(path)")
}

private func formatNumber(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
    return String(format: "%.4f", v)
}
