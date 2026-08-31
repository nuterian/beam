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
    private weak var view: GridView?
    /// Ground truth, for the third time (PLAN.md §5-L2, §5.3, §5.5). An idle
    /// bench looks like the one bench that does not need a visible screen —
    /// it measures a process doing nothing. It is the opposite: on an occluded
    /// screen every present is DROPPED, and a dropped present makes the render
    /// loop recover, which wakes the display link, which is precisely the thing
    /// being measured. Occluded, this bench reported **1.3% of a core** for
    /// code that measures 0.1%, and it published it, because it was the only
    /// timed bench with no validity check left in the project.
    private var presentsOK = 0
    private var presentsDropped = 0

    init(seconds: Int, outPath: String, view: GridView?) {
        self.seconds = seconds
        self.outPath = outPath
        self.view = view
    }

    func start() {
        view?.onProbePresent = { [weak self] presentedTime in
            guard let self else { return }
            if presentedTime > 0 { self.presentsOK += 1 } else { self.presentsDropped += 1 }
        }
        if Sabotage.idleSpin {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let until = monotonicNow() + 0.02
                while monotonicNow() < until {}
            }
        }
        // Two windows, because there are now two idle states worth knowing
        // apart (PLAN.md §5.5). The caret pulses for `caretBlinkWindow` seconds
        // after the last input and then stops, so:
        //
        //   1. the FIRST window lands inside the blink and measures what an
        //      animated caret actually costs, and
        //   2. the SECOND starts after the blink has finished and measures true
        //      idle — the display link paused, nothing moving — which is what
        //      `idle_cpu_foreground_alone_pct_core` has always meant and still
        //      means.
        //
        // Measuring only the first would quietly redefine the idle gate into a
        // caret gate; measuring only the second would leave the caret's cost
        // ungated entirely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            measure { blinkPct, _ in
                let restAt = GridView.caretBlinkWindow + 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + restAt) { [self] in
                    measure { idlePct, rss in
                        // The caret pulses through the first window, so a
                        // healthy run has presents in it. None landing means an
                        // occluded screen, and every number above is then a
                        // measurement of drop-recovery rather than of Beam.
                        let total = self.presentsOK + self.presentsDropped
                        let delivered = total > 0 ? Double(self.presentsOK) / Double(total) : 0
                        if total < 10 || delivered < 0.9 {
                            FileHandle.standardError.write(String(
                                format: "idle bench INVALID: %.0f%% of presents reached the glass (%d of %d) — an occluded screen makes the render loop recover, which is the opposite of idle\n",
                                delivered * 100, self.presentsOK, total).data(using: .utf8)!)
                            exit(5)
                        }
                        print(String(format: "caret blinking: %.3f%% core   true idle: %.3f%% core   RSS %.1f MB   presents %.0f%% delivered",
                                     blinkPct, idlePct, rss, delivered * 100))
                        do {
                            try writeResult(to: self.outPath, metrics: [
                                "L7_steady_state.idle_cpu_foreground_alone_pct_core": idlePct,
                                "L7_steady_state.caret_blink_cpu_pct_core": blinkPct,
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
        }
    }

    /// One CPU/RSS window of `seconds`.
    private func measure(_ done: @escaping (Double, Double) -> Void) {
        let cpuBefore = processCPUSeconds()
        let t0 = monotonicNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
            let wall = monotonicNow() - t0
            done((processCPUSeconds() - cpuBefore) / wall * 100, currentRSSMB())
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
