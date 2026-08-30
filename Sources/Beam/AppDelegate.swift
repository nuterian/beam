import AppKit
import BeamCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var window: NSWindow!
    private var view: GridView!
    private var bench: TypingBench?
    private var discovery: DiscoveryService?

    init(config: AppConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Sabotage.launchDelayMs > 0 { usleep(UInt32(Sabotage.launchDelayMs) * 1000) }

        let renderer: Renderer
        do {
            renderer = try Renderer(pointSize: 14, scale: NSScreen.main?.backingScaleFactor ?? 2)
        } catch {
            FileHandle.standardError.write("BEAM_LAUNCH_FAILED: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

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
    }

    /// Called (on main) with the presentedTime of the very first frame.
    private func firstFrame(_ presentedTime: Double) {
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
            print(String(format: "launch_to_first_frame_ms=%.2f", launchMs))
            print(String(format: "launch_to_typeable_ms=%.2f", typeableMs))
            exit(0)
        case .benchTyping(let n, let out):
            bench = TypingBench(view: view, window: window, n: n, outPath: out)
            bench?.start()
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
