import AppKit
import QuartzCore
import BeamCore

/// The one view: a CAMetalLayer-backed NSView that owns the render loop and
/// all input. There is no other view in Beam, and no AppKit control anywhere —
/// the roster, the join code, the cursors and the HUD are all instances in the
/// same draw call (PLAN.md §5.1). t0 for every keystroke is NSEvent.timestamp
/// (IOHID-derived).
final class GridView: NSView {
    let renderer: Renderer
    let app: AppModel
    let recorder = LatencyRecorder()

    /// Fired once, with the presentedTime of the first frame (any thread).
    var onFirstFrame: ((Double) -> Void)?
    /// Raw present outcomes for --probe-presents (main queue; 0 = dropped).
    var onProbePresent: ((Double) -> Void)?
    /// A frame carrying a REMOTE peer's keystroke reached the glass:
    /// (sender's t0, our presentedTime). Same machine ⇒ one clock domain, so
    /// this subtraction is legitimate; the cross-machine rig rows still use
    /// RTT decomposition (PLAN.md §3.1). Kept out of `recorder` so remote
    /// frames can never contaminate the L2 local-latency numbers.
    var onRemotePresented: ((Double, Double) -> Void)?
    /// Fired with the presentedTime of the first frame showing a peer row —
    /// L1.launch_to_peers_visible_ms is photon-adjacent, not a model callback.
    var onPeersPresented: ((Double) -> Void)?
    /// Fired with the presentedTime of the first frame showing the join code.
    var onCodePresented: ((Double) -> Void)?
    /// Fired with the presentedTime of each frame showing the editor surface.
    var onEditorPresented: ((Double) -> Void)?
    var flashOnKey = false
    /// Bench-only. `NSWindow.occlusionState` only ever reports `.visible` for a
    /// window whose app has activated, and activation is exclusive — so in a
    /// two-process bench one side is permanently "occluded" and renders
    /// nothing, which is right for the product (PLAN.md §4.6) and useless for
    /// measuring. When this is set the loop keeps rendering and validity is
    /// judged by the GROUND TRUTH instead: whether presents actually reach the
    /// glass (`presentedTime > 0`). That is a stronger check than the proxy,
    /// not a weaker one — a genuinely covered window drops every present and
    /// the bench fails loudly.
    var assumeVisible = false
    /// p99 budget for the HUD color (from perf/budgets.json — same file CI reads).
    var hudP99BudgetMs: Double = 18

    /// Diagnostic counters: how much work a "quiet" session actually does.
    private(set) var renderCount = 0
    private(set) var tickCount = 0

    private var firstFrameReported = false
    private var offscreenRetries = 0
    private var renderGeneration = 0

    // Hybrid render loop (PLAN.md §2): a keystroke arriving with the pipeline
    // cold (link paused) renders immediately; while the link is warm, input
    // coalesces to the tick — exactly one render per frame, so burst input
    // can never starve the 2-deep drawable queue. The link pauses after
    // ~1.5 s of quiet so idle CPU stays ~0.
    //
    // Presents can be DROPPED (presentedTime 0) — measured: the first
    // one-shot present after ~2 s of idle drops in every present mode, and
    // the drop callback only fires when a LATER present flushes the queue, so
    // recovery must be proactive: every accounted render gets a confirm
    // deadline; unconfirmed-and-not-superseded frames re-render via the tick,
    // carrying the ORIGINAL t0 so the sample includes the drop penalty.
    //
    // Phase 2 adds remote input to the same loop rather than a second path:
    // a peer's keystroke is input too, and it earns the same cold/warm
    // treatment and the same honest worst-case accounting.
    private struct PendingInput {
        let t0: Double
        let remote: Bool
    }
    private var displayLink: CADisplayLink?
    private var renderedThisFrame = false
    private var dirty = false
    /// Oldest unpresented input — carried into the next render so coalesced or
    /// recovered keystrokes record their true (worst-case) latency.
    private var pending: PendingInput?
    private var idleTicks = 0
    /// The pending repaint is only a changed status value, so it must not
    /// extend the loop's warm window — otherwise a 2 Hz RTT update keeps the
    /// display link running at 60 Hz forever and the loop never pauses at all.
    private var pendingIsStatusOnly = false
    private let idleTicksBeforePause = 90
    private var lastConfirmedGeneration = 0
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer, app: AppModel) {
        self.renderer = renderer
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        app.onNeedsRender = { [weak self] in self?.requestRender() }
        app.onNeedsStatusRender = { [weak self] in self?.requestStatusRender() }
        app.onRemoteEdit = { [weak self] t0 in self?.noteInput(t0: t0, remote: true) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.maximumDrawableCount = 2  // one frame of buffering less; PLAN.md §2
        l.isOpaque = true
        if Renderer.presentMode == .transaction { l.presentsWithTransaction = true }
        // Experiment lever for the present-path investigation (default on):
        if ProcessInfo.processInfo.environment["BEAM_NO_DISPLAY_SYNC"] == "1" {
            l.displaySyncEnabled = false
        }
        return l
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        requestRender()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Re-render when visibility changes: an occluded window's presents are
        // dropped (presentedTime 0), so the reveal must repaint immediately —
        // the same rule that will keep a hidden peer's sync + reveal instant
        // (PLAN.md §4.6).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            if window.occlusionState.contains(.visible) { self?.requestRender() }
        }
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0 && size.height > 0 { metalLayer.drawableSize = size }
    }

    /// Whether frames from this window can reach the display. See `assumeVisible`.
    var isOnGlass: Bool {
        assumeVisible || (window?.occlusionState.contains(.visible) ?? false)
    }

    private var visibleCols: Int {
        max(1, Int(metalLayer.drawableSize.width) / renderer.atlas.cellWidthPx - 2)
    }
    private var visibleRows: Int {
        max(1, Int(metalLayer.drawableSize.height) / renderer.atlas.cellHeightPx - 1)
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let t0 = event.timestamp  // IOHID-derived; same clock as presentedTime
        recorder.recordQueueTransit((monotonicNow() - t0) * 1000)
        if Sabotage.keyDelayMs > 0 { usleep(UInt32(Sabotage.keyDelayMs) * 1000) }

        if event.modifierFlags.contains(.command) {
            // ⌘Q is the entire menu. There is nothing else to put in one.
            if event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }
            return
        }

        switch app.surface {
        case .roster:
            // A number IS the gesture. Nothing else on this screen does anything.
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                  scalar.value >= 49, scalar.value <= 57,
                  app.join(peerIndex: Int(scalar.value) - 49) else { return }
            return  // join() repainted already — the local acknowledgment
        case .pairing:
            if event.keyCode == 36 { app.confirmJoin() }        // return: the host's one keypress
            else if event.keyCode == 53 { app.leaveSession() }  // esc
            return
        case .editor:
            if event.keyCode == 53 { app.leaveSession(); return }
            switch event.keyCode {
            case 123, 124, 125, 126:
                // Arrows move the cursor and tell the peer where it went, so
                // their view of your caret stays keystroke-accurate rather than
                // only updating when you type.
                let dx = event.keyCode == 123 ? -1 : (event.keyCode == 124 ? 1 : 0)
                let dy = event.keyCode == 125 ? 1 : (event.keyCode == 126 ? -1 : 0)
                app.grid.move(dx: dx, dy: dy)
                app.publishLocal(.cursor,
                                 Session.u16Bytes(app.grid.cursor.col) + Session.u16Bytes(app.grid.cursor.row))
            case 36:
                app.grid.newline()
                app.publishLocal(.newline, AppModel.editPayload(t0: t0))
            case 51:
                app.grid.backspace()
                app.publishLocal(.backspace, AppModel.editPayload(t0: t0))
            default:
                guard let scalar = event.characters?.unicodeScalars.first,
                      scalar.value >= 32, scalar.value < 127 else { return }
                app.grid.typeAscii(UInt8(scalar.value))
                app.publishLocal(.insert, AppModel.editPayload(t0: t0, [UInt8(scalar.value)]))
            }
        }

        if flashOnKey { renderer.flashFramesRemaining = 1 }
        noteInput(t0: t0, remote: false)
        if flashOnKey {
            // Follow-up frame returns to normal content for the next camera cycle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestRender() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard app.surface == .roster else { return }
        // The roster's rows are grid rows; the hit test is arithmetic, which is
        // what having no views buys.
        let p = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        let cellH = CGFloat(renderer.atlas.cellHeightPx) / scale
        // Flip to top-down grid rows; originPx offsets by half a cell.
        let row = Int((bounds.height - p.y - cellH / 2) / cellH)
        app.join(peerIndex: row - Scene.firstPeerRow)
    }

    /// One input, local or remote, entering the hybrid loop.
    private func noteInput(t0: Double, remote: Bool) {
        let visible = isOnGlass
        let cold = displayLink?.isPaused ?? true
        pendingIsStatusOnly = false
        if !visible {
            // Occluded: presents are guaranteed drops — paint on reveal. The
            // model has already been updated, so a hidden peer stays in sync
            // and catches up in one frame (PLAN.md §4.6).
            dirty = true
            if pending == nil { pending = PendingInput(t0: t0, remote: remote) }
        } else if cold {
            // Cold pipeline: render immediately AND arm a follow-up tick
            // render with the same t0 (wake-double-present) — the first
            // one-shot present after idle can be dropped, and waiting for the
            // confirm deadline costs ~3 extra frames (measured: idle-key p50
            // 92 ms deadline-driven vs. one tick here). The recorder dedupes
            // by t0, so whichever present lands first records the sample.
            render(t0: t0, remote: remote)
            renderedThisFrame = true
            dirty = true
            if pending == nil { pending = PendingInput(t0: t0, remote: remote) }
        } else if !renderedThisFrame {
            // Warm, first input of this frame: render now — coalescing every
            // keystroke to the tick taxes normal typing a half-frame
            // (measured: paced commit p50 0.3 -> 9.6 ms when fully coalesced).
            renderedThisFrame = true
            render(t0: t0, remote: remote)
        } else {
            // Warm, already rendered this frame: coalesce (burst input).
            dirty = true
            if pending == nil { pending = PendingInput(t0: t0, remote: remote) }
        }
        if visible { resumeDisplayLink() }
    }

    // MARK: - Display link

    private func resumeDisplayLink() {
        idleTicks = 0
        if displayLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    static let debug = ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1"

    @objc private func displayTick(_ link: CADisplayLink) {
        // Occluded → presents are guaranteed drops. Never spin: pause, keep
        // the dirty bit, and let the occlusion notification wake us to paint
        // the latest state instantly on reveal (PLAN.md §4.6).
        if !isOnGlass {
            link.isPaused = true
            return
        }
        tickCount += 1
        renderedThisFrame = false
        // Fades are finite: this keeps the link awake for ~200 ms and then it
        // pauses like any other quiet period. Nothing in Beam animates forever.
        if !dirty && app.isAnimating(monotonicNow()) { dirty = true }
        if dirty {
            dirty = false
            let statusOnly = pendingIsStatusOnly
            if !statusOnly { idleTicks = 0 }
            pendingIsStatusOnly = false
            let p = pending
            pending = nil
            renderedThisFrame = true
            // A status frame gets no drop recovery here either. Recovery
            // resumes the display link, and resuming it once per RTT update was
            // enough to keep the loop awake for the entire quiet window —
            // measured as idle CPU drifting from 0.20% to 0.63% run to run.
            render(t0: p?.t0, remote: p?.remote ?? false, recover: !statusOnly)
        } else {
            idleTicks += 1
            if idleTicks > idleTicksBeforePause { link.isPaused = true }
        }
    }

    // MARK: - Rendering

    /// Repaint for a value that merely CHANGED — a peer's RTT — rather than
    /// for input or structure. Waking the display link for these was measured
    /// at 3.4% of a core with an idle session: each 2 Hz probe resumed the link
    /// and held it running at 60 Hz for its full 1.5 s idle window, so the
    /// loop never paused at all. A status change is worth exactly one frame.
    func requestStatusRender() {
        guard firstFrameReported else { requestRender(); return }
        if displayLink?.isPaused == false {
            if !dirty { pendingIsStatusOnly = true }
            dirty = true   // already awake; ride the next tick, but don't extend it
        } else {
            // One shot, no drop recovery, and stay asleep. Recovery exists so a
            // KEYSTROKE is never lost to a dropped present; a status number has
            // no such claim — if this present drops, the next change repaints
            // it. Recovering here was measured at 3.1% of a core with an idle
            // session (each 2 Hz repaint dropped, and the recovery woke the
            // display link for its full 1.5 s window, so it never paused).
            render(t0: nil, recover: false)
        }
    }

    /// Render with no latency accounting (layout, expose, roster changes).
    func requestRender() {
        if firstFrameReported {
            dirty = true
            pendingIsStatusOnly = false
            resumeDisplayLink()
        } else {
            render(t0: nil, remote: false)  // launch path: direct renders until first frame lands
        }
    }

    func render(t0: Double?, remote: Bool = false, recover: Bool = true) {
        guard window != nil, metalLayer.drawableSize.width > 0 else { return }
        renderCount += 1
        renderGeneration &+= 1
        let generation = renderGeneration
        if t0 != nil {
            // Proactive drop recovery: the drop callback is unreliable (it can
            // arrive seconds late), so confirm within ~3 frames or re-render.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.050) { [weak self] in
                guard let self, self.lastConfirmedGeneration < generation,
                      self.renderGeneration == generation else { return }
                self.dirty = true
                if self.pending == nil { self.pending = PendingInput(t0: t0!, remote: remote) }
                self.resumeDisplayLink()
            }
        }
        // What this frame will show, captured before it is encoded, so the
        // "peers visible" / "code visible" marks name the frame that actually
        // carried them rather than whatever is true when the present lands.
        let showsPeers = app.surface == .roster && !app.peers.isEmpty
        let showsCode = app.surface == .pairing && !(app.session?.sas ?? "").isEmpty
        let showsEditor = app.surface == .editor

        let count = buildInstances(into: renderer.acquireInstanceStaging())
        renderer.renderStaged(
            layer: metalLayer,
            instanceCount: count,
            onCommit: (remote ? nil : t0).map { start in
                { commitTime in
                    DispatchQueue.main.async { self.recorder.recordCommit((commitTime - start) * 1000) }
                }
            },
            onPresented: { [weak self] presentedTime in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.onProbePresent?(presentedTime)
                    if Self.debug && presentedTime <= 0 {
                        FileHandle.standardError.write("present DROP gen=\(generation)\n".data(using: .utf8)!)
                    }
                    guard presentedTime > 0 else {
                        // Dropped present (presentedTime == 0). Two cases, one
                        // policy — re-present:
                        // 1. Launch: window not on glass yet (still ordering
                        //    in, or occluded — WindowServer drops presents
                        //    from occluded windows). Retry until first frame;
                        //    the occlusion notification also re-triggers.
                        // 2. MEASURED: the first one-shot present after ~2 s
                        //    of idle is structurally dropped, in every present
                        //    mode (PLAN.md §5-L2). Recovery carries the
                        //    ORIGINAL t0 so the recorded latency includes the
                        //    drop penalty — the number the user actually feels
                        //    on the first keystroke after a pause.
                        if !self.firstFrameReported {
                            self.offscreenRetries += 1
                            let delay = self.offscreenRetries < 120 ? 0.008 : 0.1
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.requestRender() }
                        } else if generation == self.renderGeneration && recover {
                            // Fast path when the drop callback IS timely; the
                            // confirm deadline above is the reliable backstop.
                            self.dirty = true
                            if let start = t0, self.pending == nil {
                                self.pending = PendingInput(t0: start, remote: remote)
                            }
                            self.resumeDisplayLink()
                        }
                        return
                    }
                    self.lastConfirmedGeneration = max(self.lastConfirmedGeneration, generation)
                    if let start = t0 {
                        if remote { self.onRemotePresented?(start, presentedTime) }
                        else { self.recorder.recordPresented(t0: start, presented: presentedTime) }
                    }
                    if showsPeers { self.onPeersPresented?(presentedTime) }
                    if showsCode {
                        self.app.noteCodePresented()
                        self.onCodePresented?(presentedTime)
                    }
                    if showsEditor { self.onEditorPresented?(presentedTime) }
                    if !self.firstFrameReported {
                        self.firstFrameReported = true
                        self.onFirstFrame?(presentedTime)
                    }
                }
            }
        )
    }

    /// Writes the whole frame straight into the renderer's staging buffer (no
    /// intermediate array — this is the keystroke hot path). Returns the count.
    private func buildInstances(into out: UnsafeMutablePointer<Renderer.Instance>) -> Int {
        var w = InstanceWriter(out, cap: Renderer.maxInstances)
        let now = monotonicNow()
        let cols = visibleCols, rows = visibleRows
        switch app.surface {
        case .roster:
            Scene.roster(app, into: &w, now: now, cols: cols)
        case .pairing:
            Scene.pairing(app, sas: app.session?.sas ?? "", into: &w, now: now)
        case .editor:
            Scene.editor(app, into: &w, now: now, cols: cols, rows: rows)
            let (text, ink) = hudLine()
            Scene.hud(into: &w, text: text, ink: ink, cols: cols, rows: rows)
        }
        return w.count
    }

    /// Live latency against the same budgets.json CI reads, plus the peer's
    /// live RTT — red the moment a live number exceeds budget (PLAN.md §3.1).
    private func hudLine() -> (String, Renderer.Ink) {
        guard let stats = recorder.hudPresentedStats() else { return ("", .dim) }
        var text = String(format: "p50 %.1f  p99 %.1f ms", stats.p50, stats.p99)
        if let r = app.remote, !app.rttText.isEmpty {
            text += "   \(r.name) \(app.rttText)"
        }
        return (text, stats.p99 <= hudP99BudgetMs ? .green : .red)
    }
}
