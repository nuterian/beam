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
    var flashOnKey = false
    var statusText = "" { didSet { if statusText != oldValue { requestRender() } } }
    /// p99 budget for the HUD color (from perf/budgets.json — same file CI reads).
    var hudP99BudgetMs: Double = 18

    private var firstFrameReported = false
    private var offscreenRetries = 0
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
        // Experiment lever for the present-path investigation (default on):
        if ProcessInfo.processInfo.environment["BEAM_NO_DISPLAY_SYNC"] == "1" {
            l.displaySyncEnabled = false
        }
        l.isOpaque = true
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

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0 && size.height > 0 { metalLayer.drawableSize = size }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let t0 = event.timestamp  // IOHID-derived; same clock as presentedTime
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
        render(t0: t0)
        if flashOnKey {
            // Follow-up frame returns to normal content for the next camera cycle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestRender() }
        }
    }

    // MARK: - Rendering

    /// Render with no latency accounting (layout, expose, status changes).
    func requestRender() { render(t0: nil) }

    func render(t0: Double?) {
        guard window != nil, metalLayer.drawableSize.width > 0 else { return }
        let instances = buildInstances()
        renderer.render(
            layer: metalLayer,
            instances: instances,
            onCommit: t0.map { start in
                { commitTime in
                    DispatchQueue.main.async { self.recorder.recordCommit((commitTime - start) * 1000) }
                }
            },
            onPresented: { [weak self] presentedTime in
                guard let self else { return }
                DispatchQueue.main.async {
                    // presentedTime == 0 means the drawable never reached the
                    // display (e.g. committed before the window was on screen).
                    guard presentedTime > 0 else {
                        if !self.firstFrameReported && self.offscreenRetries < 120 {
                            self.offscreenRetries += 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { self.requestRender() }
                        }
                        return
                    }
                    if let start = t0 {
                        self.recorder.recordPresented((presentedTime - start) * 1000)
                    }
                    if !self.firstFrameReported {
                        self.firstFrameReported = true
                        self.onFirstFrame?(presentedTime)
                    }
                }
            }
        )
    }

    private func buildInstances() -> [Renderer.Instance] {
        var out: [Renderer.Instance] = []
        out.reserveCapacity(4096)
        let visibleCols = max(1, Int(metalLayer.drawableSize.width) / renderer.atlas.cellWidthPx - 2)
        let visibleRows = max(1, Int(metalLayer.drawableSize.height) / renderer.atlas.cellHeightPx - 1)

        for row in 0..<min(model.rows, visibleRows) {
            for col in 0..<min(model.cols, visibleCols) {
                let c = model.cells[row * model.cols + col]
                if c == 0 { continue }
                if let g = GlyphAtlas.glyphIndex(forAscii: c) {
                    out.append(Renderer.Instance(col: UInt16(col), row: UInt16(row), glyph: g, color: 0))
                }
            }
        }
        // Block cursor.
        if model.cursorRow < visibleRows && model.cursorCol < visibleCols {
            out.append(Renderer.Instance(col: UInt16(model.cursorCol), row: UInt16(model.cursorRow),
                                         glyph: GlyphAtlas.blockGlyphIndex, color: 3))
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
            for (i, ch) in hud.unicodeScalars.enumerated() where ch.value >= 32 && ch.value < 127 {
                if let g = GlyphAtlas.glyphIndex(forAscii: UInt8(ch.value)) {
                    out.append(Renderer.Instance(col: UInt16(startCol + i), row: row, glyph: g, color: hudColor))
                }
            }
        }
        return out
    }
}
