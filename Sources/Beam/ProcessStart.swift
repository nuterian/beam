import Foundation

/// Process exec time expressed in the monotonic uptime clock domain (the same
/// domain as NSEvent.timestamp and CAMetalDrawable.presentedTime), so
/// launch -> first-frame is a single-clock subtraction. Source: kinfo_proc
/// p_starttime (walltime) shifted by the boot-walltime offset.
func processStartUptime() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard rc == 0 else { return ProcessInfo.processInfo.systemUptime }
    let tv = info.kp_proc.p_starttime
    let startWall = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    let bootWall = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    return startWall - bootWall
}
