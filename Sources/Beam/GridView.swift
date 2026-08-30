import AppKit
import QuartzCore
import BeamCore

/// The one view: a CAMetalLayer-backed NSView that echoes keystrokes into the
/// grid and renders event-driven (no display link while idle — idle CPU ≈ 0;
/// PLAN.md §2). t0 for every keystroke is NSEvent.timestamp (IOHID-derived).
final class GridView: NSView {
    let renderer: Renderer
    let model = GridModel()
    let recorder = LatencyRecorder()

    /// Fired once, with the presentedTime of the first frame (any thread).
    var onFirstFrame: ((Double) -> Void)?
    /// Raw present outcomes for --probe-presents (main queue; 0 = dropped).
    var onProbePresent: ((Double) -> Void)?
    var flashOnKey = false
    var statusText = "" { didSet { if statusText != oldValue { requestRender() } } }
    /// p99 budget for the HUD color (from perf/budgets.json — same file CI reads).
    var hudP99BudgetMs: Double = 18

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
    private var displayLink: CADisplayLink?
    private var renderedThisFrame = false
    private var dirty = false
    /// Oldest unpresented input timestamp — carried into the next render so
    /// coalesced/recovered keystrokes record their true (worst-case) latency.
    private var pendingT0: Double?
    private var idleTicks = 0
    private let idleTicksBeforePause = 90
    private var lastConfirmedGeneration = 0
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
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

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let t0 = event.timestamp  // IOHID-derived; same clock as presentedTime
        if ProcessInfo.processInfo.environment["BEAM_DEBUG"] == "1" {
            FileHandle.standardError.write("keyDown \(event.characters ?? "?")\n".data(using: .utf8)!)
        }
        recorder.recordQueueTransit((monotonicNow() - t0) * 1000)
        if Sabotage.keyDelayMs > 0 { usleep(UInt32(Sabotage.keyDelayMs) * 1000) }

        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }
            return
        }
        switch event.keyCode {
        case 36: model.newline()      // return
        case 51: model.backspace()    // delete
        default:
            if let scalar = event.characters?.unicodeScalars.first, scalar.value >= 32, scalar.value < 127 {
                model.typeAscii(UInt8(scalar.value))
            } else { return }
        }

        if flashOnKey { renderer.flashFramesRemaining = 1 }
        let visible = window?.occlusionState.contains(.visible) ?? false
        let cold = displayLink?.isPaused ?? true
        if !visible {
            // Occluded: presents are guaranteed drops — paint on reveal.
            dirty = true
            if pendingT0 == nil { pendingT0 = t0 }
        } else if cold {
            // Cold pipeline: render immediately AND arm a follow-up tick
            // render with the same t0 (wake-double-present) — the first
            // one-shot present after idle can be dropped, and waiting for the
            // confirm deadline costs ~3 extra frames (measured: idle-key p50
            // 92 ms deadline-driven vs. one tick here). The recorder dedupes
            // by t0, so whichever present lands first records the sample.
            render(t0: t0)
            renderedThisFrame = true
            dirty = true
            if pendingT0 == nil { pendingT0 = t0 }
        } else if !renderedThisFrame {
            // Warm, first input of this frame: render now — coalescing every
            // keystroke to the tick taxes normal typing a half-frame
            // (measured: paced commit p50 0.3 -> 9.6 ms when fully coalesced).
            renderedThisFrame = true
            render(t0: t0)
        } else {
            // Warm, already rendered this frame: coalesce (burst input).
            dirty = true
            if pendingT0 == nil { pendingT0 = t0 }
        }
        if visible { resumeDisplayLink() }
        if flashOnKey {
            // Follow-up frame returns to normal content for the next camera cycle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestRender() }
        }
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
        if Self.debug { FileHandle.standardError.write("tick dirty=\(dirty)\n".data(using: .utf8)!) }
        // Occluded → presents are guaranteed drops. Never spin: pause, keep
        // the dirty bit, and let the occlusion notification wake us to paint
        // the latest state instantly on reveal (PLAN.md §4.6).
        if !(window?.occlusionState.contains(.visible) ?? false) {
            link.isPaused = true
            return
        }
        renderedThisFrame = false
        if dirty {
            dirty = false
            idleTicks = 0
            let t0 = pendingT0
            pendingT0 = nil
            renderedThisFrame = true
            render(t0: t0)
        } else {
            idleTicks += 1
            if idleTicks > idleTicksBeforePause { link.isPaused = true }
        }
    }

    // MARK: - Rendering

    /// Render with no latency accounting (layout, expose, status changes).
    func requestRender() {
        if firstFrameReported {
            dirty = true
            resumeDisplayLink()
        } else {
            render(t0: nil)  // launch path: direct renders until first frame lands
        }
    }

    func render(t0: Double?) {
        guard window != nil, metalLayer.drawableSize.width > 0 else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        if t0 != nil {
            // Proactive drop recovery: the drop callback is unreliable (it can
            // arrive seconds late), so confirm within ~3 frames or re-render.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.050) { [weak self] in
                guard let self, self.lastConfirmedGeneration < generation,
                      self.renderGeneration == generation else { return }
                self.dirty = true
                if self.pendingT0 == nil { self.pendingT0 = t0 }
                self.resumeDisplayLink()
            }
        }
        let count = buildInstances(into: renderer.acquireInstanceStaging())
        renderer.renderStaged(
            layer: metalLayer,
            instanceCount: count,
            onCommit: t0.map { start in
                { commitTime in
                    DispatchQueue.main.async { self.recorder.recordCommit((commitTime - start) * 1000) }
                }
            },
            onPresented: { [weak self] presentedTime in
                guard let self else { return }
                DispatchQueue.main.async {
                    if Self.debug {
                        FileHandle.standardError.write("presented \(presentedTime > 0 ? "ok" : "DROP") gen=\(generation) t0=\(t0 != nil)\n".data(using: .utf8)!)
                    }
                    self.onProbePresent?(presentedTime)
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
                        } else if generation == self.renderGeneration {
                            // Fast path when the drop callback IS timely; the
                            // confirm deadline above is the reliable backstop.
                            self.dirty = true
                            if let start = t0, self.pendingT0 == nil { self.pendingT0 = start }
                            self.resumeDisplayLink()
                        }
                        return
                    }
                    self.lastConfirmedGeneration = max(self.lastConfirmedGeneration, generation)
                    if let start = t0 {
                        self.recorder.recordPresented(t0: start, presented: presentedTime)
                    }
                    if !self.firstFrameReported {
                        self.firstFrameReported = true
                        self.onFirstFrame?(presentedTime)
                    }
                }
            }
        )
    }

    /// Writes instances straight into the renderer's staging buffer (no
    /// intermediate array — this is the keystroke hot path). Returns the count.
    private func buildInstances(into out: UnsafeMutablePointer<Renderer.Instance>) -> Int {
        var n = 0
        let visibleCols = max(1, Int(metalLayer.drawableSize.width) / renderer.atlas.cellWidthPx - 2)
        let visibleRows = max(1, Int(metalLayer.drawableSize.height) / renderer.atlas.cellHeightPx - 1)
        let cap = Renderer.maxInstances

        let rows = min(model.rows, visibleRows)
        let cols = min(model.cols, visibleCols)
        model.cells.withUnsafeBufferPointer { cells in
            for row in 0..<rows {
                let base = row * model.cols
                for col in 0..<cols {
                    let c = cells[base + col]
                    if c < 32 || c >= 127 || n == cap { continue }
                    out[n] = Renderer.Instance(col: UInt16(col), row: UInt16(row),
                                               glyph: UInt16(c - 32), color: 0)
                    n += 1
                }
            }
        }
        // Block cursor.
        if model.cursorRow < visibleRows && model.cursorCol < visibleCols && n < cap {
            out[n] = Renderer.Instance(col: UInt16(model.cursorCol), row: UInt16(model.cursorRow),
                                       glyph: GlyphAtlas.blockGlyphIndex, color: 3)
            n += 1
        }
        // HUD v0, bottom-right: live latency vs. budget + status. Same
        // budgets.json CI reads; red the moment the live p99 exceeds it.
        var hud = statusText
        var hudColor: UInt16 = 3
        if let stats = recorder.hudPresentedStats() {
            hud = String(format: "p50 %.1f  p99 %.1f ms", stats.p50, stats.p99)
                + (statusText.isEmpty ? "" : "   " + statusText)
            hudColor = stats.p99 <= hudP99BudgetMs ? 2 : 1
        }
        if !hud.isEmpty {
            let row = UInt16(max(0, visibleRows - 1))
            let startCol = max(0, visibleCols - hud.count)
            for (i, ch) in hud.unicodeScalars.enumerated()
            where ch.value >= 32 && ch.value < 127 && n < cap {
                out[n] = Renderer.Instance(col: UInt16(startCol + i), row: row,
                                           glyph: UInt16(ch.value - 32), color: hudColor)
                n += 1
            }
        }
        return n
    }
}
