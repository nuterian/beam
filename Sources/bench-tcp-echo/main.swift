import Foundation
import Network
import BeamCore

// L3 transport bench: 64-byte TCP ping-pong over loopback between two real
// processes (this binary spawns itself with --server). Reports p50/p95/p99/
// p99.9/max and the Nagle/delayed-ACK spike count (samples >35 ms), which
// gates at 0 — the TCP_NODELAY regression detector.
//
// Sabotage hooks (PLAN.md §3.2 — prove the gate can go red):
//   BEAM_SABOTAGE_NO_NODELAY=1     real config regression: skip noDelay on both ends
//   BEAM_SABOTAGE_ECHO_DELAY_US=n  server sleeps n µs before every echo
//   BEAM_BENCH_N=n                 iteration count (default 10000)

let env = ProcessInfo.processInfo.environment
let sabotageNoNodelay = env["BEAM_SABOTAGE_NO_NODELAY"] == "1"
let sabotageEchoDelayUs = UInt32(env["BEAM_SABOTAGE_ECHO_DELAY_US"] ?? "") ?? 0
let iterations = Int(env["BEAM_BENCH_N"] ?? "") ?? 10_000
let warmup = min(200, iterations / 10)
let spikeThresholdMs = 35.0
let msgSize = 64

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = !sabotageNoNodelay
    let params = NWParameters(tls: nil, tcp: tcp)
    params.allowLocalEndpointReuse = true
    return params
}

let args = CommandLine.arguments

// ---------- server mode ----------
if let i = args.firstIndex(of: "--server"), i + 1 < args.count, let port = UInt16(args[i + 1]) {
    let listener = try! NWListener(using: tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
    let queue = DispatchQueue(label: "beam.echo.server")
    listener.newConnectionHandler = { conn in
        conn.start(queue: queue)
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data, !data.isEmpty {
                    if sabotageEchoDelayUs > 0 { usleep(sabotageEchoDelayUs) }
                    conn.send(content: data, completion: .contentProcessed { _ in })
                }
                if done || error != nil { conn.cancel(); return }
                pump()
            }
        }
        pump()
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state { print("READY"); fflush(stdout) }
        if case .failed(let e) = state { FileHandle.standardError.write("server failed: \(e)\n".data(using: .utf8)!); exit(2) }
    }
    listener.start(queue: queue)
    // Die if orphaned (the client exits without terminating us — e.g. a crash
    // or a killed pipeline). Reparenting to launchd (ppid 1) is the signal.
    let orphanTimer = DispatchSource.makeTimerSource(queue: queue)
    orphanTimer.schedule(deadline: .now() + 2, repeating: 2)
    orphanTimer.setEventHandler { if getppid() == 1 { exit(0) } }
    orphanTimer.resume()
    dispatchMain()
}

// ---------- client / orchestrator mode ----------
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let outPath = argValue("--out") ?? "perf/results/l3-tcp-echo.json"
let port = UInt16.random(in: 20000...60000)

let child = Process()
child.executableURL = URL(fileURLWithPath: args[0])
child.arguments = ["--server", String(port)]
let pipe = Pipe()
child.standardOutput = pipe
try! child.run()
defer { child.terminate() }

// Wait for READY from the child.
var readyBuf = Data()
while !String(data: readyBuf, encoding: .utf8)!.contains("READY") {
    let chunk = pipe.fileHandleForReading.availableData
    if chunk.isEmpty { FileHandle.standardError.write("server exited before READY\n".data(using: .utf8)!); exit(2) }
    readyBuf.append(chunk)
}

let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: tcpParameters())
let queue = DispatchQueue(label: "beam.echo.client")
let readySem = DispatchSemaphore(value: 0)
conn.stateUpdateHandler = { state in
    if case .ready = state { readySem.signal() }
    if case .failed(let e) = state { FileHandle.standardError.write("connect failed: \(e)\n".data(using: .utf8)!); exit(2) }
}
conn.start(queue: queue)
if readySem.wait(timeout: .now() + 10) == .timedOut { FileHandle.standardError.write("connect timeout\n".data(using: .utf8)!); exit(2) }

let payload = Data(repeating: 0x42, count: msgSize)
var samplesMs: [Double] = []
samplesMs.reserveCapacity(iterations)

for i in 0..<(warmup + iterations) {
    let t0 = monotonicNow()
    let sem = DispatchSemaphore(value: 0)
    conn.send(content: payload, completion: .contentProcessed { error in
        if let error { FileHandle.standardError.write("send failed: \(error)\n".data(using: .utf8)!); exit(2) }
    })
    var received = 0
    func recv() {
        conn.receive(minimumIncompleteLength: msgSize - received, maximumLength: msgSize - received) { data, _, _, error in
            if let error { FileHandle.standardError.write("recv failed: \(error)\n".data(using: .utf8)!); exit(2) }
            received += data?.count ?? 0
            if received >= msgSize { sem.signal() } else { recv() }
        }
    }
    recv()
    if sem.wait(timeout: .now() + 30) == .timedOut { FileHandle.standardError.write("echo timeout at iteration \(i)\n".data(using: .utf8)!); exit(3) }
    if i >= warmup { samplesMs.append((monotonicNow() - t0) * 1000) }
}

let p = summarize(samplesMs)
let spikes = samplesMs.filter { $0 > spikeThresholdMs }.count
print(String(format: "loopback TCP echo %dB, n=%d: p50 %.3f  p95 %.3f  p99 %.3f  p99.9 %.3f  max %.3f ms; spikes>%.0fms: %d",
             msgSize, samplesMs.count, p.p50, p.p95, p.p99, p.p999, p.max, spikeThresholdMs, spikes))

try! writeResult(to: outPath, metrics: [
    "L3_transport.loopback_tcp_echo_64b_p50_ms": p.p50,
    "L3_transport.loopback_tcp_echo_64b_p99_ms": p.p99,
    "L3_transport.nagle_spikes_in_10k_msgs": Double(spikes),
])
child.terminate()  // exit() below skips defers — terminate explicitly
exit(0)
