import AppKit
import QuartzCore
import BeamCore

/// The one view: a CAMetalLayer-backed NSView that owns the render loop and
/// all input. There is no other view in Beam, and no AppKit control anywhere —
/// the document, the gutter, the overlay, the join code, the carets and the
/// status line are all instances in the same two draw calls (PLAN.md §5.1,
/// §5.3). t0 for every keystroke is NSEvent.timestamp (IOHID-derived).
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

    // MARK: - The caret's blink (PLAN.md §5.5)
    //
    // §5.1 refused to blink, and the refusal was half right. The half that
    // stands: nothing may animate FOREVER, because an endless animation pins
    // the display link awake and puts a permanent floor under idle CPU. The
    // half that was wrong: that this ruled out a blink at all. A blink that
    // STOPS is finite, and finite is all the rule ever required.
    //
    // So: solid while you type, pulsing after a beat of stillness, and solid
    // again after `caretBlinkWindow`. And it is *opacity*, never position —
    // §5.2's refusal of caret easing stands untouched, because a caret that
    // slides to where you typed manufactures perceived latency in the one
    // product that exists to delete it, and a caret that fades does not move
    // at all.
    private var lastInputAt = monotonicNow()
    private var wasPulsing = false
    private var lastPresentedPhase: Float = -2
    /// The next moment the curve moves enough to be worth a frame. Every tick
    /// before it returns after one comparison.
    ///
    /// This is where the blink's cost actually lives. Presenting ~7 frames a
    /// second is cheap; doing trigonometry and asking AppKit whether the window
    /// is key **sixty** times a second, forever, is not — measured at 2.0% of a
    /// core against a 0.5% budget on the first attempt. The curve is flat for
    /// 89% of its period and its shape is known in advance, so the tick can be
    /// told when to bother instead of working it out each time.
    private var nextCaretChangeAt: Double = 0
    /// Cached rather than polled. `NSWindow.isKeyWindow` is an AppKit call, and
    /// an AppKit call on a 60 Hz tick is a 60 Hz AppKit call.
    private var windowIsKey = false
    /// Wakes the loop at the start of the next ramp. Between ramps the display
    /// link is **paused**, which is the difference between a blink that costs a
    /// 60 Hz callback for ten seconds and one that costs eight ticks a second.
    private var caretWake: Timer?
    /// Solid while typing and for a beat afterwards, so the blink never
    /// competes with the thing you are actually doing.
    private static let caretSolidGrace = 0.5
    /// And then it stops. This is the number that keeps idle CPU a feature.
    static let caretBlinkWindow = 10.0

    /// Seconds into the blink, or negative for "rest solid".
    var caretTime: Float {
        guard app.surface == .editor, windowIsKey else { return -1 }
        return caretTime(at: monotonicNow())
    }

    private func caretTime(at now: Double) -> Float {
        let t = now - lastInputAt
        guard t >= Self.caretSolidGrace, t < Self.caretBlinkWindow else { return -1 }
        return Float(t - Self.caretSolidGrace)
    }

    /// The same curve the shader evaluates, used **only** to decide whether a
    /// frame would look any different. The shader is authoritative for what is
    /// drawn; this is a change detector, and it is what makes an animated caret
    /// affordable: the curve is flat for most of its period, so most ticks
    /// present nothing at all. Measured frames drop from 60/s to about 7.
    private static func caretAlpha(_ t: Float) -> Float {
        guard t >= 0 else { return 1 }
        let c = cos(t * 2 * .pi / Renderer.caretPeriod)
        return min(1, max(0.12, 0.12 + 0.88 * min(1, max(0, c * 3 + 0.5))))
    }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer, app: AppModel) {
        self.renderer = renderer
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        app.onNeedsRender = { [weak self] in self?.requestRender() }
        app.onNeedsStatusRender = { [weak self] in self?.requestStatusRender() }
        app.onRemoteEdit = { [weak self] t0 in self?.noteInput(t0: t0, remote: true) }
        app.onOverlayChanged = { [weak self] in self?.updateTrackingAreas() }
        app.onRunCommand = { [weak self] id in
            guard let self, let c = Commands.command(id: id) else { return }
            c.run(self)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        // sRGB-encoded target + an explicitly sRGB layer colourspace: the blend
        // happens in linear light and the compositor is told exactly what the
        // bytes mean, so what a screenshot shows is what the glass shows
        // (PLAN.md §5.2).
        l.pixelFormat = Renderer.pixelFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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
        windowIsKey = window.isKeyWindow
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                self.windowIsKey = window.isKeyWindow
                self.nextCaretChangeAt = 0
                // Losing focus should settle the caret solid, not freeze it
                // wherever the pulse happened to be.
                if !self.windowIsKey, self.wasPulsing {
                    self.wasPulsing = false
                    self.lastPresentedPhase = -2
                    self.renderer.rePresentCaret(layer: self.metalLayer, caretTime: -1)
                }
                self.resumeDisplayLink()
            }
        }
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        // Rounded to whole device pixels. A fractional drawable puts the whole
        // grid on a half-pixel offset, which on a glyph atlas is not a subtle
        // difference: every cell then samples across its atlas neighbour's edge.
        let size = CGSize(width: (bounds.width * scale).rounded(),
                          height: (bounds.height * scale).rounded())
        if size.width > 0 && size.height > 0 { metalLayer.drawableSize = size }
    }

    /// Whether frames from this window can reach the display. See `assumeVisible`.
    var isOnGlass: Bool {
        assumeVisible || (window?.occlusionState.contains(.visible) ?? false)
    }

    private var visibleCols: Int {
        renderer.atlas.metrics.cols(forWidthPx: Int(metalLayer.drawableSize.width))
    }
    private var visibleRows: Int {
        renderer.atlas.metrics.rows(forHeightPx: Int(metalLayer.drawableSize.height))
    }

    // MARK: - Input

    /// The whole keymap (PLAN.md §5.3). It is longer than §5.1's one line
    /// because there is now a document — and every binding except ⌘K is one
    /// macOS already taught the user, which is most of what "feels like a GUI"
    /// actually means.
    override func keyDown(with event: NSEvent) {
        let t0 = event.timestamp  // IOHID-derived; same clock as presentedTime
        recorder.recordQueueTransit((monotonicNow() - t0) * 1000)
        if Sabotage.keyDelayMs > 0 { usleep(UInt32(Sabotage.keyDelayMs) * 1000) }

        if event.modifierFlags.contains(.command) {
            commandKey(event, t0: t0)
            return
        }
        if app.overlay != nil {
            // An overlay keystroke goes through the same hybrid loop as any
            // other input — otherwise the repaint is untimed and
            // `overlay_keystroke_to_commit_p99_ms` measures nothing.
            overlayKey(event, t0: t0)
            noteInput(t0: t0, remote: false)
            return
        }

        switch app.surface {
        case .pairing:
            if event.keyCode == 36 { app.confirmJoin() }        // return: the host's one keypress
            else if event.keyCode == 53 { app.leaveSession() }  // esc
            return
        case .editor:
            editorKey(event, t0: t0)
        }
    }

    /// Command keys go through the one command table (`Commands.all`), so a
    /// shortcut does the same thing whether it arrived from the menu bar or
    /// straight through the window. Benches depend on the second path:
    /// `window.sendEvent` never reaches the menu.
    private func commandKey(_ event: NSEvent, t0: Double) {
        if event.charactersIgnoringModifiers?.lowercased() == "q",
           event.modifierFlags.contains(.command) {
            NSApp.terminate(nil)
            return
        }
        guard let command = Commands.matching(event) else { return }
        perform(command, t0: t0)
    }

    /// Runs a command and accounts it.
    ///
    /// **A command is input.** Undo, switching a tab and opening the palette all
    /// change what is on the glass in response to a key, so they enter the same
    /// hybrid render loop and are held to the same latency as a keystroke —
    /// which is what `tab_switch_to_presented_60hz_p99_ms` gates.
    ///
    /// Both routes come through here, and they must: in the shipping app the
    /// **menu bar** claims every key equivalent before `keyDown` ever runs, so a
    /// command reaches the view through `AppDelegate.runCommand`; a bench drives
    /// `window.sendEvent`, which never reaches the menu, and lands in `keyDown`.
    /// If only one of them were accounted, the bench would be measuring a path
    /// no user takes.
    func perform(_ command: Command, t0: Double?) {
        command.run(self)
        if let t0 { noteInput(t0: t0, remote: false) } else { requestRender() }
    }

    /// Undo/redo, with the caret revealed and published — shared by the command
    /// table so the menu item and the shortcut cannot diverge.
    func applyHistory(redo: Bool) {
        guard app.overlay == nil, app.surface == .editor else { return }
        guard redo ? app.doc.applyRedo() : app.doc.applyUndo() else { return }
        revealCaret()
        app.publishCaret()
        requestRender()
    }

    /// Keys while an overlay is open. Every one of them is either a filter
    /// character or a way out — an overlay you cannot leave with `esc` is a
    /// mode, and Beam does not have modes.
    private func overlayKey(_ event: NSEvent, t0: Double) {
        _ = t0
        switch event.keyCode {
        case 53: app.closeOverlay(); return                     // esc
        case 36: app.overlayCommit(); return                    // return
        case 125: app.overlayMove(1); return                    // down
        case 126: app.overlayMove(-1); return                   // up
        case 51: app.overlayBackspace(); return                 // delete
        default: break
        }
        guard let chars = event.characters, !chars.isEmpty else { return }
        // A digit in the PEER list is the join gesture — §5.1's "a number joins
        // that peer", kept exactly, one layer in. The file list has no numbers,
        // so a digit there is just a digit to search with.
        if app.overlay == .peers, let scalar = chars.unicodeScalars.first,
           scalar.value >= 49, scalar.value <= 57 {
            app.overlaySelect(Int(scalar.value) - 49)
            app.overlayCommit()
            return
        }
        let printable = String(chars.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
        guard !printable.isEmpty else { return }
        app.overlayType(printable)
    }

    private func editorKey(_ event: NSEvent, t0: Double) {
        let doc = app.doc
        let extend = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)

        switch event.keyCode {
        case 53:                       // esc — leave the session, keep the document
            if app.session != nil { app.leaveSession() }
            else if doc.selection != nil { doc.placeCaret(at: doc.caret, extend: false) }
            else { return }
            noteInput(t0: t0, remote: false)
            return
        case 123, 124, 125, 126:       // arrows
            let motion: Document.Motion
            switch event.keyCode {
            case 123: motion = .left
            case 124: motion = .right
            case 125: motion = .down
            default:  motion = .up
            }
            doc.move(motion, extend: extend, pageRows: app.viewportRows)
            revealCaret()
            app.publishCaret()
        case 115: doc.move(.docStart, extend: extend); revealCaret(); app.publishCaret()   // home
        case 119: doc.move(.docEnd, extend: extend); revealCaret(); app.publishCaret()     // end
        case 116: doc.move(.pageUp, extend: extend, pageRows: app.viewportRows); revealCaret(); app.publishCaret()
        case 121: doc.move(.pageDown, extend: extend, pageRows: app.viewportRows); revealCaret(); app.publishCaret()
        case 36:                       // return
            _ = doc.insert([0x0A])
            revealCaret()
            app.publishLocal(.newline, AppModel.editPayload(t0: t0))
        case 48:                       // tab — a real tab byte; Document expands it to cells
            _ = doc.insert([0x09])
            revealCaret()
            app.publishLocal(.insert, AppModel.editPayload(t0: t0, [0x09]))
        case 51:                       // delete
            guard doc.deleteBackward() != nil else { return }
            revealCaret()
            app.publishLocal(.backspace, AppModel.editPayload(t0: t0))
        case 117:                      // forward delete
            guard doc.deleteForward() != nil else { return }
            revealCaret()
            app.publishCaret()
        default:
            guard !option, let chars = event.characters, !chars.isEmpty else { return }
            // Every scalar the keyboard produced, not just ASCII: the atlas
            // fills on demand now, and dropping a character because it is not
            // in 32...126 is the bug §5.3 fixed rather than a policy.
            let text = String(chars.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
            guard !text.isEmpty else { return }
            _ = doc.insert(Array(text.utf8))
            revealCaret()
            // The wire op is still Phase 2's single byte; a multi-byte scalar
            // is sent as its bytes in order, which the peer reassembles in the
            // same order. Phase 3 replaces the whole op with a `yrs` update.
            for b in Array(text.utf8) {
                app.publishLocal(.insert, AppModel.editPayload(t0: t0, [b]))
            }
        }

        if flashOnKey { renderer.flashFramesRemaining = 1 }
        noteInput(t0: t0, remote: false)
        if flashOnKey {
            // Follow-up frame returns to normal content for the next camera cycle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestRender() }
        }
    }

    private func revealCaret() {
        app.doc.revealCaret(cellWidthPx: renderer.atlas.cellWidthPx,
                            cellHeightPx: renderer.atlas.cellHeightPx,
                            viewportRows: app.viewportRows, viewportCols: app.viewportCols)
    }

    // MARK: - Mouse

    /// The rule that decides what a press does: **the chrome is the drag
    /// handle, the document is the document** (PLAN.md §5.3). Beam has no title
    /// bar, so a press on the filename row, the status line, or the margins
    /// moves the window; a press inside the text viewport places the caret.
    private func gridPosition(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        let cellW = CGFloat(renderer.atlas.cellWidthPx) / scale
        let cellH = CGFloat(renderer.atlas.cellHeightPx) / scale
        let originX = CGFloat(renderer.atlas.cellWidthPx) / scale
        let originY = CGFloat(renderer.atlas.cellHeightPx / 2) / scale
        return (Int(floor((p.x - originX) / cellW)),
                Int(floor((bounds.height - p.y - originY) / cellH)))
    }

    /// The document offset under a grid cell, accounting for the sub-cell
    /// scroll: the row you clicked is the row you *saw*, which after a
    /// pixel-quantized scroll is not the row the cell grid would name.
    private func offset(atCol col: Int, row: Int) -> Int {
        let doc = app.doc
        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: doc.buffer.lineCount)
        let cellH = renderer.atlas.cellHeightPx
        let topLine = doc.scrollPx / cellH
        let subPx = doc.scrollPx % cellH
        // A row scrolled up by subPx covers a click that lands subPx lower.
        let visualRow = row - L.topRow + (subPx > cellH / 2 ? 1 : 0)
        let line = min(max(0, topLine + visualRow), doc.buffer.lineCount - 1)
        let column = col - L.codeCol + doc.scrollXPx / max(1, renderer.atlas.cellWidthPx)
        return doc.offset(line: line, cellColumn: max(0, column))
    }

    private var isSelecting = false

    override func mouseDown(with event: NSEvent) {
        let (col, row) = gridPosition(event)
        if let kind = app.overlay {
            let pcol = Scene.overlayCol(cols: visibleCols)
            let i = Scene.overlayIndex(atRow: row)
            if col >= pcol, col < pcol + Scene.overlayWidth,
               i >= 0, i < app.overlayItems.count {
                app.overlaySelect(i)
                app.overlayCommit()
            } else {
                // Clicking outside the panel dismisses it. An overlay you have
                // to aim at an X to close is chrome pretending to be a dialog.
                _ = kind
                app.closeOverlay()
            }
            return
        }
        guard app.surface == .editor else { window?.performDrag(with: event); return }

        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: app.doc.buffer.lineCount)

        // A tab: select it, or close it by its ×.
        if row == L.tabRow {
            var handled = false
            Scene.forEachTab(app, L) { i, start, width in
                guard !handled, col >= start, col < start + width else { return }
                handled = true
                let isCloseMark = i == app.activeIndex && !app.documents[i].isModified
                    && col == start + 2 + app.tabTitle(i).unicodeScalars.count + 1
                if isCloseMark { app.closeDocument(at: i) } else { app.selectDocument(i) }
            }
            if handled { requestRender(); return }
            window?.performDrag(with: event)
            return
        }

        // The rail.
        if col < L.railCols, row >= L.railTopRow {
            let i = Scene.railIndex(atRow: row, L)
            if i >= 0, i < Scene.railItems.count,
               let command = Commands.command(id: Scene.railItems[i].commandID) {
                // Clicking the item that is already open closes it, which is
                // what every activity bar does and what a toggle should do.
                if app.overlay == Scene.railItems[i].overlay { app.closeOverlay() }
                else { command.run(self) }
                return
            }
            window?.performDrag(with: event)
            return
        }

        guard row >= L.topRow, row < L.statusRow, col >= 0 else {
            window?.performDrag(with: event)
            return
        }
        let target = offset(atCol: col, row: row)
        app.doc.placeCaret(at: target, extend: event.modifierFlags.contains(.shift))
        if event.clickCount >= 2 { selectWord(around: target) }
        isSelecting = true
        app.publishCaret()
        noteInput(t0: event.timestamp, remote: false)
    }

    override func mouseDragged(with event: NSEvent) {
        if app.overlay != nil { return }
        guard isSelecting else { return }
        let (col, row) = gridPosition(event)
        app.doc.placeCaret(at: offset(atCol: col, row: row), extend: true)
        revealCaret()
        app.publishCaret()
        noteInput(t0: event.timestamp, remote: false)
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
    }

    /// Hover, and only while an overlay is open. Editor-wide mouse tracking
    /// would wake the render loop on every motion — the exact shape of the
    /// 3.4%-idle-CPU regression Phase 2 caught (PLAN.md §5.3).
    override func mouseMoved(with event: NSEvent) {
        guard app.overlay != nil else { return }
        let (col, row) = gridPosition(event)
        let pcol = Scene.overlayCol(cols: visibleCols)
        let i = Scene.overlayIndex(atRow: row)
        let hover = (col >= pcol && col < pcol + Scene.overlayWidth
                     && i >= 0 && i < app.overlayItems.count) ? i : -1
        guard hover != app.overlayHover else { return }
        app.overlayHover = hover
        requestRender()
    }

    /// The tracking area is installed **with** the overlay and removed with it.
    /// A permanently installed one would deliver a main-thread event for every
    /// pixel of mouse motion over a window that has nothing to hover — the
    /// exact shape of the 3.4%-idle-CPU regression Phase 2 caught, and the
    /// thing PLAN.md §5.3 says does not happen.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        guard app.overlay != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func selectWord(around offset: Int) {
        let buf = app.doc.buffer
        func isWord(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39) || b == 0x5F || b >= 0x80
        }
        var lo = offset, hi = offset
        while lo > 0, isWord(buf.byte(at: lo - 1)) { lo -= 1 }
        while hi < buf.count, isWord(buf.byte(at: hi)) { hi += 1 }
        guard hi > lo else { return }
        app.doc.anchor = lo
        app.doc.caret = hi
    }

    /// Scrolling, in **device pixels**.
    ///
    /// macOS delivers momentum as its own event stream, so inertia costs Beam
    /// no animation at all: there is nothing to drive, nothing to keep the
    /// display link awake, and the flick ends when the OS stops sending. That
    /// is why scrolling here does not violate the "nothing infinite" rule that
    /// keeps idle CPU at zero (PLAN.md §5.1).
    override func scrollWheel(with event: NSEvent) {
        guard app.surface == .editor, app.overlay == nil else { return }
        if Sabotage.scrollDelayMs > 0 { usleep(UInt32(Sabotage.scrollDelayMs) * 1000) }
        let scale = window?.backingScaleFactor ?? 2
        let doc = app.doc
        let dy = Int((event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                      : event.scrollingDeltaY * 3) * scale)
        let dx = Int((event.hasPreciseScrollingDeltas ? event.scrollingDeltaX
                                                      : event.scrollingDeltaX * 3) * scale)
        let beforeY = doc.scrollPx, beforeX = doc.scrollXPx
        doc.scrollPx -= dy
        doc.clampScroll(cellHeightPx: renderer.atlas.cellHeightPx, viewportRows: app.viewportRows)
        // Horizontal stays cell-quantized: a monospace grid has no sub-cell
        // horizontal position to be at.
        let cellW = renderer.atlas.cellWidthPx
        doc.scrollXPx = max(0, ((doc.scrollXPx - dx) / cellW) * cellW)
        guard doc.scrollPx != beforeY || doc.scrollXPx != beforeX else { return }
        noteInput(t0: event.timestamp, remote: false)
    }

    /// One input, local or remote, entering the hybrid loop.
    private func noteInput(t0: Double, remote: Bool) {
        let visible = isOnGlass
        if !remote {
            lastInputAt = monotonicNow()
            nextCaretChangeAt = 0
            lastPresentedPhase = -2
            caretWake?.invalidate()
            caretWake = nil
        }
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

    /// How long the curve stays visually still from here — the flat top or the
    /// flat bottom of the pulse. Derived from the same shaped cosine the shader
    /// draws, so the two cannot disagree about when something is happening.
    private static func secondsUntilCurveMoves(_ t: Float) -> Double {
        let p = Double(Renderer.caretPeriod)
        // The curve is clamped whenever |cos(2*pi*t/p)| > 1/6; it starts moving
        // at the next crossing of that threshold.
        let edge = acos(1.0 / 6.0) / (2 * .pi) * p            // ~0.268 s
        let phase = Double(t).truncatingRemainder(dividingBy: p)
        for boundary in [edge, p - edge, p + edge] where boundary > phase {
            return max(0, boundary - phase)
        }
        return 0
    }

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
        let now = monotonicNow()
        // Fades are finite: this keeps the link awake for ~200 ms and then it
        // pauses like any other quiet period. Nothing in Beam animates forever.
        if !dirty && app.isAnimating(now) { dirty = true }
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
        } else if windowIsKey, app.surface == .editor, caretTime(at: now) >= 0 {
            // Pulsing. Keep the loop awake, but do NOTHING until the curve is
            // due to move: it is flat for 89% of its period, and a tick that
            // would present an identical frame should not even compute one.
            idleTicks = 0
            wasPulsing = true
            if now >= nextCaretChangeAt {
                let phase = caretTime(at: now)
                let alpha = Self.caretAlpha(phase)
                if abs(alpha - lastPresentedPhase) > 1.0 / 255 {
                    lastPresentedPhase = alpha
                    renderer.rePresentCaret(layer: metalLayer, caretTime: phase)
                    nextCaretChangeAt = 0                 // mid-ramp: check every tick
                    return
                }
                nextCaretChangeAt = now + Self.secondsUntilCurveMoves(phase)
            }
            // The curve is flat until `nextCaretChangeAt`, which is about half
            // a second away — far longer than the loop's 1.5 s idle threshold
            // would ever notice, so it would keep ticking at 60 Hz for the
            // whole ten-second window doing nothing. Sleep instead, and set an
            // alarm for the ramp. The link then runs only while something is
            // actually moving: roughly eight ticks a second rather than sixty.
            let rest = nextCaretChangeAt - now
            if rest > 0.05 {
                link.isPaused = true
                caretWake?.invalidate()
                caretWake = Timer.scheduledTimer(withTimeInterval: rest, repeats: false) {
                    [weak self] _ in self?.resumeDisplayLink()
                }
            }
        } else {
            if wasPulsing {
                // The window closed mid-pulse. One last frame so the caret
                // rests solid rather than wherever the curve happened to be.
                wasPulsing = false
                caretWake?.invalidate()
                caretWake = nil
                lastPresentedPhase = -2
                renderer.rePresentCaret(layer: metalLayer, caretTime: -1)
            }
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
        // L1.launch_to_peers_visible_ms moved with presence: the mark is the
        // frame that first carries a peer's CHIP IN THE STATUS LINE, which is
        // where the roster went (PLAN.md §5.3, and the re-specification is
        // written into budgets.json). Same instrument, same fade floor — the
        // frame that claims the number is still one a human could read.
        let showsPeers = app.surface == .editor && !app.peers.isEmpty && app.remote == nil
        let showsCode = app.surface == .pairing && !(app.session?.sas ?? "").isEmpty
        let showsEditor = app.surface == .editor

        let planes = buildInstances(into: renderer.acquireInstanceStaging())
        renderer.renderStaged(
            layer: metalLayer,
            planes: planes,
            caretTime: caretTime,
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
    /// intermediate array — this is the keystroke hot path) and returns the two
    /// planes it is laid out in.
    ///
    /// **Document first, chrome second.** They are separate draws because they
    /// disagree about where the grid starts: the document's origin carries the
    /// sub-cell scroll offset and its scissor is the text viewport, which is
    /// what makes scrolling pixel-quantized instead of cell-quantized
    /// (PLAN.md §5.3). Chrome draws after, so an overlay's scrim composites
    /// over the document rather than under it.
    private func buildInstances(into out: UnsafeMutablePointer<Renderer.Instance>) -> [Renderer.Plane] {
        GlyphCache.shared.beginFrame()
        var w = InstanceWriter(out, cap: Renderer.maxInstances)
        let now = monotonicNow()
        let cols = visibleCols, rows = visibleRows
        // Publish the metrics and the viewport the model needs for scroll,
        // paging and hit-testing. The model never asks the GPU anything, which
        // is what lets --dump-scene lay out the shipping grid with no Metal.
        app.cellWidthPx = renderer.atlas.cellWidthPx
        app.cellHeightPx = renderer.atlas.cellHeightPx
        let layout = Scene.EditorLayout(cols: cols, rows: rows, lineCount: app.doc.buffer.lineCount)
        app.viewportRows = layout.docRows
        app.viewportCols = layout.textCols
        return Scene.frame(app, into: &w, now: now, cols: cols, rows: rows,
                           widthPx: Int(metalLayer.drawableSize.width), hud: hudSpans())
    }

    /// Live latency against the same budgets.json CI reads, plus the peer's
    /// live RTT — red the moment a live number exceeds budget (PLAN.md §3.1).
    ///
    /// Set as spans rather than one string: the labels are faint, the values
    /// carry the colour, the units are quiet again. These numbers are the
    /// product, so they are the brightest thing on the line and everything
    /// around them gets out of their way.
    /// Built fresh each frame, and left that way on purpose. This is the
    /// keystroke hot path, so a reused buffer looks like the obvious win — but
    /// `malloc_bytes_per_keystroke` has measured −81, −1.4, +8.6 and +29 across
    /// runs of the same code. A ~110-byte spread cannot resolve the ~10 bytes
    /// an array of eleven spans costs, so keeping the capacity is an
    /// *unmeasured* optimisation, and this project does not merge those
    /// (PLAN.md §5.1, on the browser-pause lever left unwired for the same
    /// reason). It stays simple until a bench can tell the difference.
    private func hudSpans() -> [Scene.Span] {
        guard let stats = recorder.hudPresentedStats() else { return [] }
        let ink: Renderer.Ink = stats.p99 <= hudP99BudgetMs ? .green : .red
        var spans = [
            Scene.Span("p50 ", .faint),
            Scene.Span(String(format: "%.1f", stats.p50), ink),
            Scene.Span("  p99 ", .faint),
            Scene.Span(String(format: "%.1f", stats.p99), ink),
            Scene.Span(" ms", .faint),
        ]
        if let r = app.remote, !app.rttText.isEmpty {
            spans.append(Scene.Span("   ", .faint))
            spans.append(Scene.Span(glyph: GlyphAtlas.chipGlyphIndex, .peer(r.inkIndex)))
            spans.append(Scene.Span(" ", .faint))
            spans.append(Scene.Span(r.name, .dim))
            spans.append(Scene.Span(" \(app.rttText.replacingOccurrences(of: " ms", with: ""))", .fg))
            spans.append(Scene.Span(" ms", .faint))
        }
        return spans
    }
}
