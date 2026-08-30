import AppKit
import Darwin
import BeamCore

/// L7 idle bench: after the first frame settles, measure this process's CPU
/// time and RSS over a quiet window. Beam renders event-driven — no display
/// link, no polling — so idle CPU should be ~0. Idle CPU is a product feature
/// (PLAN.md §4.10) and timer wakeups are its leading indicator.
///
/// Sabotage hook: BEAM_SABOTAGE_IDLE_SPIN=1 runs a 20%-duty busy timer.
final class IdleBench {
    private let seconds: Int
    private let outPath: String
    private var spinTimer: Timer?

    init(seconds: Int, outPath: String) {
        self.seconds = seconds
        self.outPath = outPath
    }

    func start() {
        if Sabotage.idleSpin {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let until = monotonicNow() + 0.02
                while monotonicNow() < until {}
            }
        }
        // Let launch work (autorelease churn, first-frame retries) settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            let cpuBefore = processCPUSeconds()
            let t0 = monotonicNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
                let wall = monotonicNow() - t0
                let cpuPct = (processCPUSeconds() - cpuBefore) / wall * 100
                let rss = currentRSSMB()
                print(String(format: "idle over %.1f s: %.3f%% core, RSS %.1f MB", wall, cpuPct, rss))
                do {
                    try writeResult(to: outPath, metrics: [
                        "L7_steady_state.idle_cpu_foreground_alone_pct_core": cpuPct,
                        "L7_steady_state.baseline_rss_mb": rss,
                    ])
                } catch {
                    FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
                    exit(4)
                }
                exit(0)
            }
        }
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + sys
    }

    private func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
