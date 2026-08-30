import AppKit
import IOKit.pwr_mgt
import BeamCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var window: NSWindow!
    private var view: GridView!
    private var bench: TypingBench?
    private var idleBench: IdleBench?
    private var probe: PresentProbe?
    private var discovery: DiscoveryService?
    private var didFinishLaunchingAt: Double = 0
    private var rendererReadyAt: Double = 0
    private var userActivityTimer: Timer?
    private var userActivityAssertion: IOPMAssertionID = 0

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity(
            "Beam benchmark" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)
    }

    init(config: AppConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Sabotage.launchDelayMs > 0 { usleep(UInt32(Sabotage.launchDelayMs) * 1000) }
        didFinishLaunchingAt = monotonicNow()

        let renderer: Renderer
        do {
            renderer = try Renderer(pointSize: 14, scale: NSScreen.main?.backingScaleFactor ?? 2)
        } catch {
            FileHandle.standardError.write("BEAM_LAUNCH_FAILED: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        rendererReadyAt = monotonicNow()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Beam"
        window.center()
        window.isReleasedWhenClosed = false

        view = GridView(renderer: renderer)
        if case .flashOnKey = config.mode { view.flashOnKey = true }
        if let budgets = try? loadBudgets(path: defaultBudgetsPath()) {
            let fps = window.screen?.maximumFramesPerSecond ?? 60
            let key = "L2_local_render.keystroke_to_presented_\(fps >= 100 ? "120hz" : "60hz")_p99_ms"
            if let b = budgets[key]?.budget { view.hudP99BudgetMs = b }
        }
        view.onFirstFrame = { [weak self] presentedTime in self?.firstFrame(presentedTime) }
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        switch config.mode {
        case .benchTyping, .benchLaunch, .benchIdle, .verifyLaunch, .probePresents:
            // Benches must measure an unoccluded window: WindowServer drops
            // presents from occluded windows (measured: presentedTime == 0 for
            // every frame). Float above everything, on every Space — including
            // over fullscreen apps — so the machine's user can't accidentally
            // occlude a run by switching Spaces.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            // Unattended runs: the screensaver occludes everything and every
            // present drops (measured — see PLAN.md §5-L2). Declaring user
            // activity dismisses and suppresses it for the duration.
            declareUserActivity()
            userActivityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.declareUserActivity()
            }
            // Fail loudly if the first frame can't reach the glass (occluded
            // screen / screensaver) instead of retrying forever — a hung bench
            // is worse than a red one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.firstFrameSeen else { return }
                let vis = self.window.occlusionState.contains(.visible)
                FileHandle.standardError.write(
                    "BEAM_LAUNCH_TIMEOUT: no frame reached the display in 15 s (window visible=\(vis)). An occluded screen (screensaver?) drops all presents — benches need a visible screen.\n"
                        .data(using: .utf8)!)
                exit(6)
            }
        case .normal, .flashOnKey:
            break
        }
    }

    private var firstFrameSeen = false

    /// Called (on main) with the presentedTime of the very first frame.
    private func firstFrame(_ presentedTime: Double) {
        firstFrameSeen = true
        let launchMs = (presentedTime - processStartUptime()) * 1000
        // Phase 0: typeable the instant the first frame is up (first responder
        // is already set). Kept as a separate number so it can diverge later.
        let typeableMs = launchMs

        switch config.mode {
        case .verifyLaunch:
            // Direct-binary packaged verification (PLAN.md §3.2): sentinel on
            // stderr so GUI-swallowed stdout can't hide a broken boot.
            FileHandle.standardError.write("BEAM_LAUNCH_OK\n".data(using: .utf8)!)
            print(String(format: "launch_to_first_frame_ms=%.1f", launchMs))
            exit(0)
        case .benchLaunch:
            // Breakdown segments are informational (stdout only) — they tell
            // us WHERE launch time lives when the L1 gate trends up.
            let start = processStartUptime()
            print(String(format: "launch_to_first_frame_ms=%.2f", launchMs))
            print(String(format: "launch_to_typeable_ms=%.2f", typeableMs))
            print(String(format: "  exec_to_didFinishLaunching_ms=%.2f", (didFinishLaunchingAt - start) * 1000))
            print(String(format: "  renderer_init_ms=%.2f (shader compile %.2f)",
                         (rendererReadyAt - didFinishLaunchingAt) * 1000, view.renderer.shaderCompileMs))
            print(String(format: "  window_to_first_present_ms=%.2f", (presentedTime - rendererReadyAt) * 1000))
            exit(0)
        case .benchTyping(let n, let out):
            bench = TypingBench(view: view, window: window, n: n, outPath: out)
            bench?.start()
        case .benchIdle(let seconds, let out):
            idleBench = IdleBench(seconds: seconds, outPath: out)
            idleBench?.start()
        case .probePresents:
            probe = PresentProbe(view: view, window: window)
            probe?.start()
        case .normal, .flashOnKey:
            view.statusText = "beam · alone on this network"
            let d = DiscoveryService()
            d.onChange = { [weak self] count, warning in
                if let warning {
                    self?.view.statusText = "beam · \(warning)"
                } else {
                    self?.view.statusText = count == 0
                        ? "beam · alone on this network"
                        : "beam · \(count) peer\(count == 1 ? "" : "s") nearby"
                }
            }
            d.start()
            discovery = d
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
