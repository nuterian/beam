import Foundation
import BeamCore

// The perf gate. Reads every JSON file in perf/results/ (each written by a
// benchmark runner), flattens perf/budgets.json into the same dotted-key
// shape, and compares. This is the ONE place that decides pass/fail;
// benchmarks only measure and emit — they never judge their own results.
//
// Exit 0 = every present metric is within its gate. Exit 1 = at least one
// breached. Missing metrics are reported but do not fail (a phase's
// benchmarks may not exist yet) unless --require-all is passed.

let args = CommandLine.arguments
let requireAll = args.contains("--require-all")
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let budgetsPath = argValue("--budgets") ?? defaultBudgetsPath()
let resultsDir = argValue("--results") ?? "perf/results"

let budgets: [String: MetricSpec]
do {
    budgets = try loadBudgets(path: budgetsPath)
} catch {
    FileHandle.standardError.write("perf-gate: cannot load \(budgetsPath): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}

var results: [String: Double] = [:]
if let files = try? FileManager.default.contentsOfDirectory(atPath: resultsDir) {
    for f in files.sorted() where f.hasSuffix(".json") {
        let path = (resultsDir as NSString).appendingPathComponent(f)
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FileHandle.standardError.write("perf-gate: skipping unparseable \(path)\n".data(using: .utf8)!)
            continue
        }
        for (k, v) in obj {
            if let n = v as? NSNumber { results[k] = n.doubleValue }
        }
    }
}

enum Status { case pass, fail, missing }
struct Outcome {
    let key: String
    let status: Status
    let value: Double?
    let spec: MetricSpec
}

var outcomes: [Outcome] = []
for key in budgets.keys.sorted() {
    let spec = budgets[key]!
    guard let value = results[key] else {
        outcomes.append(Outcome(key: key, status: .missing, value: nil, spec: spec))
        continue
    }
    guard let gate = spec.gate else {
        outcomes.append(Outcome(key: key, status: .pass, value: value, spec: spec))
        continue
    }
    let within = spec.higherIsBetter ? value >= gate : value <= gate
    outcomes.append(Outcome(key: key, status: within ? .pass : .fail, value: value, spec: spec))
}

func fmt(_ v: Double?) -> String {
    guard let v else { return "–" }
    if v == v.rounded() && abs(v) < 1e12 { return String(Int(v)) }
    return String(format: "%.3f", v)
}

let passed = outcomes.filter { $0.status == .pass }
let failed = outcomes.filter { $0.status == .fail }
let missing = outcomes.filter { $0.status == .missing }

print("Beam perf gate — \(passed.count) pass, \(failed.count) fail, \(missing.count) missing\n")
for o in outcomes {
    switch o.status {
    case .missing:
        print("  · \(o.key) — no data")
    case .pass:
        print("  ✓ \(o.key) = \(fmt(o.value)) (budget \(fmt(o.spec.budget)), gate \(fmt(o.spec.gate)))")
    case .fail:
        print("  ✗ \(o.key) = \(fmt(o.value)) (budget \(fmt(o.spec.budget)), gate \(fmt(o.spec.gate)))")
    }
}

if !failed.isEmpty {
    print("\n\(failed.count) metric(s) breached their gate.")
    exit(1)
}
if requireAll && !missing.isEmpty {
    print("\n--require-all set: \(missing.count) metric(s) have no data.")
    exit(1)
}
print("\nGate passed.")
