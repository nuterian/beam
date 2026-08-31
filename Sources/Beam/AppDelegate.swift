import AppKit
import IOKit.pwr_mgt
import BeamCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var window: NSWindow!
    private var view: GridView?
    private var app: AppModel!
    private var bench: TypingBench?
    private var idleBench: IdleBench?
    private var joinBench: JoinBench?
    private var editorBench: EditorBench?
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
            renderer = try Renderer(pointSize: Zoom.defaultPointSize,
                                 scale: NSScreen.main?.backingScaleFactor ?? 2)
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
        // `beam <path>` opens that file. With no argument Beam launches into an
        // empty untitled buffer, deliberately: restoring a file would put disk
        // I/O inside `launch_to_typeable_ms` (PLAN.md §5.3).
        app.openAtLaunch(config.openPath)
        let view = GridView(renderer: renderer, app: app)
        self.view = view
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
        case .benchTyping, .benchIdle, .probePresents, .benchEditor:
            // These measure the local render path, so they start on a bare
            // document with no session and no discovery — which is now simply
            // the default state, and their numbers stay directly comparable
            // with every Phase-0/1 run (PLAN.md §5-L2).
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
        case .normal, .flashOnKey, .verifySession, .dumpScene, .screenshot, .benchText:
            break  // the headless modes all exit in main.swift before any window exists
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
    /// The lights sit inside the left margin every surface already reserves, so
    /// they cost the composition nothing — and row 1 of that same band carries
    /// the document's name, exactly where a title would be (PLAN.md §5.3).
    static func styleAsContent(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: CGFloat(Renderer.groundSRGB.x), green: CGFloat(Renderer.groundSRGB.y),
            blue: CGFloat(Renderer.groundSRGB.z), alpha: 1)
        window.titlebarSeparatorStyle = .none
        // Dragging the window is GridView's job, not AppKit's: the view consumes
        // mouseDown to place the caret, so the rule is `the chrome is the drag
        // handle, the document is the document` (PLAN.md §5.3) — a press on the
        // filename row, the status line or the margins moves the window.
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
            // **A machine with no display cannot be asked for a photon.**
            //
            // `--verify-launch` answers two different questions and only one of
            // them needs a screen: *did the packaged binary boot* — Metal
            // device, runtime-compiled shaders, atlas, window, first responder,
            // which is the never-again gate from PLAN.md §3.2 — and *did a
            // frame reach the glass*. On a CI runner the second is impossible
            // and its failure says nothing about the build.
            //
            // So `BEAM_ALLOW_HEADLESS=1` (set only in CI) makes the timeout a
            // pass that reports what it did NOT verify. It is opt-in for a
            // reason that is not caution: `scripts/gate.sh` uses this same mode
            // as its screensaver pre-flight, and a default that shrugged at a
            // missing frame would turn that pre-flight into a no-op and let
            // every timed bench run into a dead screen.
            if case .verifyLaunch = self.config.mode,
               ProcessInfo.processInfo.environment["BEAM_ALLOW_HEADLESS"] == "1" {
                FileHandle.standardError.write(
                    "BEAM_LAUNCH_OK\nBEAM_LAUNCH_HEADLESS: the binary booted — Metal device, shaders, atlas, window, first responder — but no frame reached the display in 15 s and this machine has \(NSScreen.screens.count) screen(s). The BOOT path is verified; the PRESENT path is not, and cannot be here.\n"
                        .data(using: .utf8)!)
                exit(0)
            }
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
        guard let view else { return }
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
            // Discovery runs here now, deliberately. Beam used to idle on a
            // roster whose whole job was discovery; it idles on a DOCUMENT with
            // discovery in the background (PLAN.md §5.3), and a bench that did
            // not start it would be measuring a state the product never has.
            // The metric is re-specified in budgets.json to say so.
            app.startDiscovery()
            idleBench = IdleBench(seconds: seconds, outPath: out, view: view)
            idleBench?.start()
        case .benchJoin(let role, let out):
            joinBench = JoinBench(view: view, window: window, app: app, role: role, outPath: out)
            joinBench?.start()
        case .probePresents:
            probe = PresentProbe(view: view, window: window)
            probe?.start()
        case .benchEditor(let out):
            editorBench = EditorBench(view: view, window: window, app: app, outPath: out)
            editorBench?.start()
        case .normal, .flashOnKey, .verifySession, .dumpScene, .screenshot, .benchText:
            app.startDiscovery()
        }
    }

    /// Every menu item lands here, tagged with its index into `Commands.all`.
    @objc func runCommand(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < Commands.all.count, let view else { return }
        // The key equivalent that opened the menu is still the current event,
        // and its IOHID timestamp is the honest t0 — a command invoked by its
        // shortcut is accounted exactly like the same command typed into the
        // view. Chosen with the mouse there is no keystroke to charge, so it
        // repaints without recording a latency sample.
        let event = NSApp.currentEvent
        let t0 = (event?.type == .keyDown) ? event?.timestamp : nil
        view.perform(Commands.all[sender.tag], t0: t0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q, held behind the same question ⌘W is (PLAN.md §5.8).
    ///
    /// This is the harder half of "it must be impossible to lose the user's
    /// work", because quitting does not pass through any document's own code
    /// — it goes through the application, so an editor that guards ⌘W and
    /// forgets ⌘Q has guarded the smaller door. `.terminateLater` is the only
    /// honest answer while a question is on the glass: the confirmation is
    /// drawn in Beam's own grid and answered on Beam's own event loop, so the
    /// verdict arrives asynchronously.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Benches, `--verify-launch` and the headless tools quit themselves on
        // purpose and have no user to ask. A question raised here would hang
        // them forever, which is a worse failure than the one it prevents.
        guard case .normal = config.mode, let app else { return .terminateNow }
        if app.confirmQuit(then: { ok in
            NSApp.reply(toApplicationShouldTerminate: ok)
        }) {
            return .terminateNow
        }
        view?.requestRender()
        return .terminateLater
    }
}
