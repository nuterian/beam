import Foundation
import Network
import BeamCore

// L5 presence bench: advertise a uniquely-named Bonjour service (_beam._tcp),
// then measure NWBrowser start -> that service appearing in browse results.
// This exercises the exact API path the app's peer list uses, including the
// macOS Local Network (TCC) permission: a denial must surface as an explicit
// red/error, never a silent empty list (PLAN.md §2).
//
// Sabotage hook: BEAM_SABOTAGE_DISCOVERY_DELAY_MS=n starts the browser first
// and delays the advertisement by n ms, so the measured time honestly includes
// the slowdown — proves the gate can go red.

let env = ProcessInfo.processInfo.environment
let sabotageDelayMs = Int(env["BEAM_SABOTAGE_DISCOVERY_DELAY_MS"] ?? "") ?? 0
let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let outPath = argValue("--out") ?? "perf/results/l5-discovery.json"
let serviceType = "_beam._tcp"
let serviceName = "beam-bench-\(getpid())"
let timeoutSeconds = 8.0

let queue = DispatchQueue(label: "beam.discovery")
let doneSem = DispatchSemaphore(value: 0)
var foundMs: Double? = nil
var browserStart: Double = 0

// Ephemeral-port NWListener fails EINVAL without allowLocalEndpointReuse on
// current macOS; explicit-port listeners are unaffected.
let listenerParams = NWParameters.tcp
listenerParams.allowLocalEndpointReuse = true
let listener = try! NWListener(using: listenerParams)
listener.service = NWListener.Service(name: serviceName, type: serviceType)
// A listener with no newConnectionHandler fails EINVAL at start.
listener.newConnectionHandler = { conn in conn.cancel() }

let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in
    for r in results {
        if case let .service(name, _, _, _) = r.endpoint, name == serviceName {
            if foundMs == nil {
                foundMs = (monotonicNow() - browserStart) * 1000
                doneSem.signal()
            }
        }
    }
}
browser.stateUpdateHandler = { state in
    switch state {
    case .failed(let e), .waiting(let e):
        FileHandle.standardError.write(
            "browser \(state): \(e)\nIf this mentions PolicyDenied/NoAuth, grant Local Network access to the launching app in System Settings > Privacy & Security > Local Network.\n".data(using: .utf8)!)
    default: break
    }
}

let advertiseReady = DispatchSemaphore(value: 0)
listener.stateUpdateHandler = { state in
    if case .ready = state { advertiseReady.signal() }
    if case .failed(let e) = state { FileHandle.standardError.write("listener failed: \(e)\n".data(using: .utf8)!); exit(2) }
}

if sabotageDelayMs > 0 {
    browserStart = monotonicNow()
    browser.start(queue: queue)
    Thread.sleep(forTimeInterval: Double(sabotageDelayMs) / 1000)
    listener.start(queue: queue)
} else {
    listener.start(queue: queue)
    if advertiseReady.wait(timeout: .now() + 5) == .timedOut {
        FileHandle.standardError.write("advertise never became ready (Local Network permission?)\n".data(using: .utf8)!)
        exit(2)
    }
    browserStart = monotonicNow()
    browser.start(queue: queue)
}

let result = doneSem.wait(timeout: .now() + timeoutSeconds)
let ms: Double
if result == .timedOut {
    FileHandle.standardError.write("peer not found within \(timeoutSeconds)s — writing a failing value. Likely cause: Local Network (TCC) permission denied for the launching app.\n".data(using: .utf8)!)
    ms = timeoutSeconds * 1000
} else {
    ms = foundMs!
}
print(String(format: "browse -> peer found: %.1f ms", ms))
try! writeResult(to: outPath, metrics: ["L5_presence_session.browse_to_peer_found_ms": ms])
browser.cancel()
listener.cancel()
exit(result == .timedOut ? 1 : 0)
