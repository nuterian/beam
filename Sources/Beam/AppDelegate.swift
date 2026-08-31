import AppKit
import IOKit.pwr_mgt
import BeamCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var window: NSWindow!
    private var view: GridView!
    private var app: AppModel!
    private var bench: TypingBench?
    private var idleBench: IdleBench?
    private var joinBench: JoinBench?
    private var probe: PresentProbe?
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Beam"
        Self.styleAsContent(window)
        window.center()
        window.isReleasedWhenClosed = false

        app = AppModel(localName: DiscoveryService.defaultName())
        view = GridView(renderer: renderer, app: app)
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
        case .benchTyping, .benchIdle, .probePresents:
            app.startInEditor()
            prepareBenchWindow()
        case .benchLaunch, .verifyLaunch:
            prepareBenchWindow()
        case .benchJoin(let role, _):
            // Two processes, and activation is exclusive: the one that is not
            // active never has its window reported visible, so it must not use
            // occlusionState to decide whether to render. Presents are the
            // ground truth here — see GridView.assumeVisible.
            view.assumeVisible = true
            // Host left, guest right: two visible, NON-OVERLAPPING windows.
            // WindowServer drops every present from an occluded window, so a
            // two-process bench that stacked its windows would measure fiction.
            prepareBenchWindow()
            if let screen = window.screen ?? NSScreen.main {
                let f = screen.visibleFrame
                let w = min(700, f.width / 2 - 20)
                let x = role == .host ? f.minX + 10 : f.minX + w + 30
                window.setFrame(NSRect(x: x, y: f.minY + 40, width: w, height: min(600, f.height - 80)),
                                display: true)
            }
        case .normal, .flashOnKey, .verifySession, .dumpScene, .screenshot:
            break  // both exit in main.swift before any window exists
        }
    }

    /// The window is nothing but content (PLAN.md §5.2). `fullSizeContentView`
    /// plus a transparent, title-less titlebar means the Metal grid runs to all
    /// four edges; the system's own corner radius and shadow come free and are
    /// the only shape Beam has. There is no chrome left to design, which is the
    /// point — what remains is the traffic lights, and they are handled rather
    /// than left to fend for themselves on a dark ground:
    ///
    /// - `darkAqua` explicitly, so they render in their dark-mode variant
    ///   (graphite when inactive, saturated on hover) instead of the light
    ///   variant, which reads as three bright dots pasted onto the grid.
    /// - The background is Beam's ground, so the rounded corners, a live
    ///   resize, and the instant before the first frame are all the same
    ///   colour rather than a flash of system gray.
    /// - No titlebar separator hairline.
    ///
    /// The lights sit inside the left margin the roster already reserves, so
    /// they cost the composition nothing — see Scene.topRow.
    static func styleAsContent(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: CGFloat(Renderer.groundSRGB.x), green: CGFloat(Renderer.groundSRGB.y),
            blue: CGFloat(Renderer.groundSRGB.z), alpha: 1)
        window.titlebarSeparatorStyle = .none
        // Dragging the window is GridView's job (`performDrag` on any press
        // that is not a peer row), not AppKit's: the view consumes mouseDown to
        // make the roster clickable, which would otherwise leave a chrome-less
        // window with no way to move it.
        window.isMovableByWindowBackground = false
    }

    /// Benches must measure an unoccluded window: WindowServer drops presents
    /// from occluded windows (measured: presentedTime == 0 for every frame).
    /// Float above everything, on every Space — including over fullscreen apps
    /// — so the machine's user can't accidentally occlude a run by switching
    /// Spaces.
    private var isJoinBench: Bool {
        if case .benchJoin = config.mode { return true }
        return false
    }

    private var occlusionPollTimer: Timer?

    /// Diagnostic only (BEAM_OCCLUSION_POLL=1): watch how this window's
    /// visibility evolves. Two-process bench runs live or die on this.
    private func startOcclusionPoll(_ tag: String) {
        var n = 0
        occlusionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n += 1
            FileHandle.standardError.write(
                "[\(tag)] t=\(n) vis=\(self.window.occlusionState.contains(.visible)) raw=\(self.window.occlusionState.rawValue) appActive=\(NSApp.isActive) key=\(self.window.isKeyWindow)\n".data(using: .utf8)!)
        }
    }

    private func prepareBenchWindow() {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["BEAM_OCCLUSION_POLL"] == "1" {
            startOcclusionPoll(ProcessInfo.processInfo.environment["BEAM_TAG"] ?? "\(getpid())")
        }
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
        case .benchJoin(let role, let out):
            joinBench = JoinBench(view: view, window: window, app: app, role: role, outPath: out)
            joinBench?.start()
        case .probePresents:
            probe = PresentProbe(view: view, window: window)
            probe?.start()
        case .normal, .flashOnKey, .verifySession, .dumpScene, .screenshot:
            app.startDiscovery()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
