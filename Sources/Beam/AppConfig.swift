import Foundation

enum RunMode {
    case normal
    case benchTyping(n: Int, out: String)
    case benchLaunch
    case benchIdle(seconds: Int, out: String)
    case benchJoin(role: JoinRole, out: String)
    case verifyLaunch
    case flashOnKey
    case probePresents
    case verifySession(out: String?)
    case dumpScene
}

enum JoinRole: String {
    case guest, host
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
        if args.contains("--bench-idle") {
            let seconds = Int(value(after: "--seconds") ?? "") ?? 5
            let out = value(after: "--out") ?? "perf/results/l7-idle.json"
            return AppConfig(mode: .benchIdle(seconds: seconds, out: out))
        }
        if args.contains("--bench-join") {
            let role = JoinRole(rawValue: value(after: "--role") ?? "guest") ?? .guest
            let out = value(after: "--out") ?? "perf/results/l5-join.json"
            return AppConfig(mode: .benchJoin(role: role, out: out))
        }
        if args.contains("--dump-scene") { return AppConfig(mode: .dumpScene) }
        if args.contains("--verify-session") {
            return AppConfig(mode: .verifySession(out: value(after: "--out")))
        }
        if args.contains("--flash-on-key") { return AppConfig(mode: .flashOnKey) }
        if args.contains("--probe-presents") { return AppConfig(mode: .probePresents) }
        return AppConfig(mode: .normal)
    }
}

enum Sabotage {
    // PLAN.md §3.2: deliberate-slowdown hooks that exist to prove gates can go red.
    static let keyDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_KEY_DELAY_MS"] ?? "") ?? 0
    static let launchDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_LAUNCH_DELAY_MS"] ?? "") ?? 0
    static let idleSpin = ProcessInfo.processInfo.environment["BEAM_SABOTAGE_IDLE_SPIN"] == "1"
    /// Stalls the pairing handshake after key agreement — what a heavier
    /// pairing scheme would feel like. Proves the L5 join gates can go red.
    static let joinDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_JOIN_DELAY_MS"] ?? "") ?? 0
    /// Delays putting a discovered peer on the glass — the peer IS on the
    /// network, we are just slow to show it. Proves L1.launch_to_peers_visible_ms
    /// can go red without faking a discovery failure.
    static let peerListDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_PEER_LIST_DELAY_MS"] ?? "") ?? 0
}
