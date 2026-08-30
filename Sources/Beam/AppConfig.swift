import Foundation

enum RunMode {
    case normal
    case benchTyping(n: Int, out: String)
    case benchLaunch
    case verifyLaunch
    case flashOnKey
}

struct AppConfig {
    let mode: RunMode

    static func parse(_ args: [String]) -> AppConfig {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--verify-launch") { return AppConfig(mode: .verifyLaunch) }
        if args.contains("--bench-launch") { return AppConfig(mode: .benchLaunch) }
        if args.contains("--bench-typing") {
            let n = Int(value(after: "--n") ?? "") ?? 400
            let out = value(after: "--out") ?? "perf/results/l2-typing.json"
            return AppConfig(mode: .benchTyping(n: n, out: out))
        }
        if args.contains("--flash-on-key") { return AppConfig(mode: .flashOnKey) }
        return AppConfig(mode: .normal)
    }
}

enum Sabotage {
    // PLAN.md §3.2: deliberate-slowdown hooks that exist to prove gates can go red.
    static let keyDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_KEY_DELAY_MS"] ?? "") ?? 0
    static let launchDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_LAUNCH_DELAY_MS"] ?? "") ?? 0
}
