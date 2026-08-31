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
//
// `--deterministic-only` judges ONLY the rows marked `deterministic` in
// budgets.json — bytes on the wire, draw calls, binary size, linked dylibs,
// packaged-launch — and reports the timing rows without letting them fail the
// run. It exists for PLAN.md §3.3's tier 1: a shared CI runner is a noisy
// virtual machine, and §3.1 says in as many words that absolute timing gates
// belong on dedicated hardware. Measured on a GitHub macOS runner the same
// commit that lexes a line in 0.6 µs here reports 0.9, and an atlas miss goes
// from 63 µs p99 to 2,687 — so gating timings there does not catch
// regressions, it just teaches everyone to ignore a red build, which is the
// most expensive thing a gate can do.

let args = CommandLine.arguments
let requireAll = args.contains("--require-all")
let deterministicOnly = args.contains("--deterministic-only")
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

enum Status { case pass, fail, missing, noisy }
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
    if !within && deterministicOnly && !spec.deterministic {
        outcomes.append(Outcome(key: key, status: .noisy, value: value, spec: spec))
        continue
    }
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
let noisy = outcomes.filter { $0.status == .noisy }

print("Beam perf gate — \(passed.count) pass, \(failed.count) fail, \(missing.count) missing"
      + (deterministicOnly ? ", \(noisy.count) over gate but NOT JUDGED (timing on a shared runner)" : "") + "\n")
for o in outcomes {
    switch o.status {
    case .missing:
        print("  · \(o.key) — no data")
    case .pass:
        print("  ✓ \(o.key) = \(fmt(o.value)) (budget \(fmt(o.spec.budget)), gate \(fmt(o.spec.gate)))")
    case .fail:
        print("  ✗ \(o.key) = \(fmt(o.value)) (budget \(fmt(o.spec.budget)), gate \(fmt(o.spec.gate)))")
    case .noisy:
        // Reported, never fatal. Silence would be worse than noise: a real
        // regression should still be visible in the log even where it cannot
        // be trusted enough to fail a build.
        print("  ~ \(o.key) = \(fmt(o.value)) over gate \(fmt(o.spec.gate)) — timing on a shared runner, not judged")
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
