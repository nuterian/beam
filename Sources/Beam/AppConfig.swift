import Foundation
import CoreGraphics

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
    case benchEditor(out: String)
    case benchText(out: String)
    case dumpScene
    case screenshot(surface: String, out: String, pointSize: CGFloat?)
}

enum JoinRole: String {
    case guest, host
}

struct AppConfig {
    let mode: RunMode
    /// `beam <path>` — the file to open at launch, if any.
    let openPath: String?

    static func parse(_ args: [String]) -> AppConfig {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // The first bare argument is a path to open. Flags all start with `--`
        // and every flag value in Beam follows its own flag, so a bare argument
        // is unambiguous.
        var openPath: String?
        var i = 1
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") { i += 2; continue }
            openPath = (a as NSString).isAbsolutePath
                ? a : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(a)
            break
        }
        if args.contains("--verify-launch") { return AppConfig(mode: .verifyLaunch, openPath: openPath) }
        if args.contains("--bench-launch") { return AppConfig(mode: .benchLaunch, openPath: openPath) }
        if args.contains("--bench-typing") {
            let n = Int(value(after: "--n") ?? "") ?? 400
            let out = value(after: "--out") ?? "perf/results/l2-typing.json"
            return AppConfig(mode: .benchTyping(n: n, out: out), openPath: openPath)
        }
        if args.contains("--bench-idle") {
            let seconds = Int(value(after: "--seconds") ?? "") ?? 5
            let out = value(after: "--out") ?? "perf/results/l7-idle.json"
            return AppConfig(mode: .benchIdle(seconds: seconds, out: out), openPath: openPath)
        }
        if args.contains("--bench-join") {
            let role = JoinRole(rawValue: value(after: "--role") ?? "guest") ?? .guest
            let out = value(after: "--out") ?? "perf/results/l5-join.json"
            return AppConfig(mode: .benchJoin(role: role, out: out), openPath: openPath)
        }
        if args.contains("--bench-editor") {
            return AppConfig(mode: .benchEditor(out: value(after: "--out") ?? "perf/results/l2-editor.json"),
                             openPath: openPath)
        }
        if args.contains("--bench-text") {
            return AppConfig(mode: .benchText(out: value(after: "--out") ?? "perf/results/l2-text.json"), openPath: openPath)
        }
        if args.contains("--dump-scene") { return AppConfig(mode: .dumpScene, openPath: openPath) }
        if args.contains("--screenshot") {
            // `--point-size` renders a surface at any zoom step, so the ladder
            // in `Zoom` can be reviewed by eye rather than trusted (PLAN.md
            // §5.7). It is what proves the derived 1:2 cell actually holds the
            // rail icons and the join code's block digits square at every size,
            // which is the claim the whole zoom feature rests on.
            let pt = value(after: "--point-size").flatMap { Double($0) }.map { CGFloat($0) }
            return AppConfig(mode: .screenshot(surface: value(after: "--surface") ?? "all",
                                               out: value(after: "--out") ?? "docs/shots",
                                               pointSize: pt),
                             openPath: openPath)
        }
        if args.contains("--verify-session") {
            return AppConfig(mode: .verifySession(out: value(after: "--out")), openPath: openPath)
        }
        if args.contains("--flash-on-key") { return AppConfig(mode: .flashOnKey, openPath: openPath) }
        if args.contains("--probe-presents") { return AppConfig(mode: .probePresents, openPath: openPath) }
        return AppConfig(mode: .normal, openPath: openPath)
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
    /// Puts a stall on the wheel-event path — what a scroll that recomputes
    /// too much per event would feel like. Proves the L2 scroll rows can go red.
    static let scrollDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_SCROLL_DELAY_MS"] ?? "") ?? 0
    /// Delays filtering in the open overlay. Proves
    /// `overlay_keystroke_to_commit_p99_ms` can go red.
    static let overlayDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_OVERLAY_DELAY_MS"] ?? "") ?? 0
    /// Stalls the atlas rebuild a zoom step performs — what a naive
    /// re-rasterization, or one that also recompiled the shader, would feel
    /// like. Proves `zoom_step_to_presented_60hz_p99_ms` can go red.
    static let zoomDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_ZOOM_DELAY_MS"] ?? "") ?? 0
    /// Makes rasterizing a glyph the atlas does not have expensive — what a
    /// naive atlas (or a font-fallback storm) would feel like on the keystroke
    /// path. Proves `L2.atlas_miss_rasterize_us` can go red.
    static let atlasMissUs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_ATLAS_MISS_US"] ?? "") ?? 0
    /// Delays putting a discovered peer on the glass — the peer IS on the
    /// network, we are just slow to show it. Proves L1.launch_to_peers_visible_ms
    /// can go red without faking a discovery failure.
    static let peerListDelayMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_PEER_LIST_DELAY_MS"] ?? "") ?? 0
}
