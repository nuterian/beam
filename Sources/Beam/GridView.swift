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
    /// Beam's animation engine: a phase per palette slot, eased on the CPU and
    /// multiplied into alpha by the shader (BeamCore.Animator).
    private var animator = Animator()
    /// The keystroke currently being interpreted by AppKit, so whatever
    /// `doCommandBySelector` decides it meant is still charged to the key the
    /// user actually pressed.
    var inputT0: Double?
    var inputDidChange = false
    /// Byte range of a live IME composition, or nil.
    var markedByteRange: Range<Int>?

    /// The phase table for this frame, with the caret folded in.
    ///
    /// The caret is not an eased transition — it is a continuous function of
    /// time — so it is *held* rather than eased, which is also why its curve
    /// belongs on the CPU beside every other curve instead of duplicated into
    /// the shader where it desynced twice (PLAN.md §5.5).
    private func phases(at now: Double) -> [Float] {
        animator.hold(Int(Renderer.Ink.caret.rawValue), at: Self.caretAlpha(caretTime))
        // Once the fade-out has finished there is nothing left to draw, so the
        // target is forgotten — held until then precisely so there IS something
        // to fade.
        if animator.phase(hoverSlot) == 0, app.hover != nil { app.hover = nil }
        return animator.phase
    }
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
    /// The shader's curve, re-derived on the CPU purely as a *change detector*.
    ///
    /// Every constant comes from `Renderer`, and that is not tidiness. This
    /// function, `secondsUntilCurveMoves` and the shader are three
    /// implementations of one curve, and when the shader's gain and the CPU's
    /// disagreed the caret was drawn in coarse steps — a defect visible only as
    /// "the blink looks cheap". Sharing the constants is what stops the three
    /// from drifting again.
    static func caretAlpha(_ t: Float) -> Float {
        guard t >= 0 else { return 1 }
        let c = cos(t * 2 * .pi / Renderer.caretPeriod)
        let s = min(1, max(0, c * Renderer.caretGain * 0.5 + 0.5))
        return Renderer.caretFloor + (1 - Renderer.caretFloor) * s
    }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer, app: AppModel) {
        self.renderer = renderer
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        app.onNeedsRender = { [weak self] in self?.requestRender() }
        app.onNeedsStatusRender = { [weak self] in self?.requestStatusRender() }
        app.onRemoteEdit = { [weak self] t0 in self?.noteInput(t0: t0, remote: true) }
        app.onOverlayChanged = { [weak self] in
            guard let self else { return }
            self.app.hover = nil
            self.animator.hold(self.hoverSlot, at: 0)
            self.animator.hold(self.hoverTextSlot, at: 0)
            self.updateTrackingAreas()
        }
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
                    self.renderer.rePresentPhases(layer: self.metalLayer, phase: self.phases(at: monotonicNow()))
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

    var visibleCols: Int {
        renderer.atlas.metrics.cols(forWidthPx: Int(metalLayer.drawableSize.width))
    }
    var visibleRows: Int {
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

    // MARK: - Clipboard

    /// The selection as text, or nil when there is none. Copy and cut both
    /// refuse silently rather than clearing the pasteboard — losing what you
    /// copied a moment ago because a later ⌘C found nothing selected is a small
    /// theft that every editor is careful to avoid.
    private func selectedText() -> String? {
        guard app.surface == .editor, app.overlay == nil,
              let sel = app.doc.selection else { return nil }
        return app.doc.buffer.string(in: sel)
    }

    func copySelection() {
        guard let text = selectedText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func cutSelection() {
        guard selectedText() != nil else { return }
        copySelection()
        guard app.doc.deleteBackward() != nil else { return }
        revealCaret()
        app.publishCaret()
        requestRender()
    }

    func paste() {
        guard app.surface == .editor, app.overlay == nil,
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        // Normalise line endings on the way in: a paste from a Windows file or
        // an old Mac one would otherwise put CR bytes in the buffer, which the
        // line index does not treat as line breaks and the atlas draws as a
        // replacement box.
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        app.doc.undo.breakCoalescing()
        _ = app.doc.insert(Array(normalised.utf8))
        revealCaret()
        for b in Array(normalised.utf8) {
            app.publishLocal(.insert, AppModel.editPayload(t0: monotonicNow(), [b]))
        }
        requestRender()
    }

    // MARK: - The context menu

    /// Right-click. Built from the same command table as the menu bar and the
    /// palette, so a command cannot exist in one and not the others.
    ///
    /// This is an `NSMenu`, which is the second and last AppKit exception after
    /// the menu bar, on the same reasoning: a menu is its own window, so it
    /// costs no in-window control, no draw call and no instance — and it brings
    /// keyboard navigation, Services and accessibility that would otherwise
    /// have to be rebuilt badly (PLAN.md §5.4).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard app.surface == .editor else { return nil }
        // Right-clicking outside the selection moves the caret there first,
        // which is what every Mac text surface does — the menu then acts on
        // what you actually pointed at.
        let offset = offsetForPoint(convert(event.locationInWindow, from: nil))
        if let sel = app.doc.selection, sel.contains(offset) {
            // keep it
        } else if app.overlay == nil {
            app.doc.placeCaret(at: offset, extend: false)
            app.doc.selectWord()
            requestRender()
        }
        let ids = ["edit.cut", "edit.copy", "edit.paste", nil,
                   "edit.selectAll", nil, "file.save", "file.open"]
        let menu = NSMenu()
        for id in ids {
            guard let id, let i = Commands.all.firstIndex(where: { $0.id == id }) else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: Commands.all[i].title,
                                  action: #selector(AppDelegate.runCommand(_:)), keyEquivalent: "")
            item.tag = i
            item.target = NSApp.delegate
            menu.addItem(item)
        }
        return menu
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

    /// Everything that is not a command goes to **AppKit**, which dispatches it
    /// to `insertText` or `doCommandBySelector` exactly as it does for an
    /// `NSTextView` (see TextInput.swift). That is what makes `⌃D`, `⌥←`, `⌥⌫`,
    /// dead keys and IME work at all, and it means the key map is the system's
    /// — including whatever the user has customised — rather than a table of
    /// key codes Beam has to keep correct.
    private func editorKey(_ event: NSEvent, t0: Double) {
        if flashOnKey { renderer.flashFramesRemaining = 1 }
        handleTextInput(event)
        if flashOnKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestRender() }
        }
    }

    /// The document offset under a point in view coordinates. Shared by the
    /// click hit-test and by the input method's `characterIndex(for:)`.
    func offsetForPoint(_ p: NSPoint) -> Int {
        let scale = window?.backingScaleFactor ?? 2
        let m = renderer.atlas.metrics
        let cellW = CGFloat(m.cellWidthPx) / scale, cellH = CGFloat(m.cellHeightPx) / scale
        let ox = CGFloat(m.originX(forWidthPx: Int(metalLayer.drawableSize.width))) / scale
        let oy = CGFloat(m.originY(forHeightPx: Int(metalLayer.drawableSize.height))) / scale
        let col = Int(floor((p.x - ox) / cellW))
        let row = Int(floor((bounds.height - p.y - oy) / cellH))
        return offset(atCol: col, row: row)
    }

    func revealCaret() {
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
        let m = renderer.atlas.metrics
        let originX = CGFloat(m.originX(forWidthPx: Int(metalLayer.drawableSize.width))) / scale
        let originY = CGFloat(m.originY(forHeightPx: Int(metalLayer.drawableSize.height))) / scale
        return (Int(floor((p.x - originX) / cellW)),
                Int(floor((bounds.height - p.y - originY) / cellH)))
    }

    /// The document offset under a grid cell, accounting for the sub-cell
    /// scroll: the row you clicked is the row you *saw*, which after a
    /// pixel-quantized scroll is not the row the cell grid would name.
    func offset(atCol col: Int, row: Int) -> Int {
        let doc = app.doc
        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: doc.buffer.lineCount)
        let cellH = renderer.atlas.cellHeightPx
        let topLine = doc.scrollPx / cellH
        let subPx = doc.scrollPx % cellH
        // **The same offset the document PLANE is drawn with** — the tab-strip
        // inset minus the sub-cell scroll remainder (Scene.frame). The row you
        // clicked is the row you *saw*, and after a pixel-quantized scroll or
        // inside a sub-cell inset that is not the row the cell grid would name.
        // Deriving it here from the same function that draws it is what stops
        // the two from disagreeing by a third of a line.
        let shiftPx = Scene.docTopGapPx(cellHeightPx: cellH) - subPx
        let visualRow = row - L.topRow - Int((Double(shiftPx) / Double(cellH)).rounded())
        let line = min(max(0, topLine + visualRow), doc.buffer.lineCount - 1)
        let column = col - L.codeCol + doc.scrollXPx / max(1, renderer.atlas.cellWidthPx)
        return doc.offset(line: line, cellColumn: max(0, column))
    }

    private var isSelecting = false

    override func mouseDown(with event: NSEvent) {
        let (col, row) = gridPosition(event)
        if let kind = app.overlay {
            let pcol = Scene.overlayCol(cols: visibleCols, kind)
            let i = Scene.overlayIndex(atRow: row)
            if col >= pcol, col < pcol + Scene.overlayWidth(kind),
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
                    && col == Scene.tabMarkCol(app, i, startCol: start)
                if isCloseMark { app.closeDocument(at: i) } else { app.selectDocument(i) }
            }
            if !handled {
                let plus = Scene.newTabCol(app, L)
                if col >= plus, col < plus + Scene.newTabCols {
                    app.newDocument()
                    handled = true
                }
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

        // The status line's actionable segments (PLAN.md §5.7). Same hit-test
        // the hover uses, so a segment that lights up is a segment that
        // responds; a readout falls through and the press moves the window,
        // which is what pressing chrome has always done.
        if row == L.statusRow, app.doc.ioError == nil,
           let i = Scene.statusSegment(atCol: col, app, L, limit: statusLimit(L)),
           let action = Scene.statusSegments(app)[i].action {
            app.openOverlay(action)
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

    /// Hover, on chrome only.
    ///
    /// The tracking areas cover the **tab strip row and the rail column, and
    /// nothing else** — never the document. That is the whole performance
    /// story: a pointer moving over code generates no events at all, so the
    /// render loop is not woken by mouse motion, which is the shape of the
    /// 3.4%-idle-CPU regression Phase 2 caught. Moving over chrome costs one
    /// event per motion and a repaint only when the *target* changes, not on
    /// every pixel.
    override func mouseMoved(with event: NSEvent) {
        updateHover(at: gridPosition(event))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: (col: -1, row: -1))
    }

    private func updateHover(at p: (col: Int, row: Int)) {
        let target = hoverTarget(atCol: p.col, row: p.row)
        guard target != app.hover || (target == nil) != (animator.phase(hoverSlot) == 0) else { return }
        let now = monotonicNow()
        if let target {
            // Moving between two chrome targets keeps the phase where it is, so
            // the highlight travels at full strength and only fades at the
            // edges of the strip — which is what a good tab bar does, and what
            // a cross-fade would get wrong.
            app.hover = target
            animator.ease(hoverSlot, to: 1, now: now)
            animator.ease(hoverTextSlot, to: 1, now: now)
        } else {
            animator.ease(hoverSlot, to: 0, now: now)
            animator.ease(hoverTextSlot, to: 0, now: now)
        }
        requestRender()
    }

    private var hoverSlot: Int { Int(Renderer.Ink.hover.rawValue) }
    private var hoverTextSlot: Int { Int(Renderer.Ink.hoverText.rawValue) }

    /// Where the status line's left-hand run has to stop: the column the
    /// latency readout begins at, less one gap. Hit-testing derives it from the
    /// **same spans the frame is drawn with**, so a segment the window is too
    /// narrow to show is also a segment that cannot be clicked.
    private func statusLimit(_ layout: Scene.EditorLayout) -> Int {
        Scene.hudStartCol(spans: Scene.presenceSpans(app, now: monotonicNow()) + hudSpans(),
                          cols: layout.cols) - Scene.statusGap
    }

    /// Which piece of chrome a cell belongs to, or nil for anything else —
    /// including every cell of the document.
    private func hoverTarget(atCol col: Int, row: Int) -> AppModel.HoverTarget? {
        guard col >= 0, row >= 0 else { return nil }
        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: app.doc.buffer.lineCount)
        if let kind = app.overlay {
            _ = kind
            let pcol = Scene.overlayCol(cols: visibleCols, app.overlay ?? .files)
            let i = Scene.overlayIndex(atRow: row)
            let width = Scene.overlayWidth(app.overlay ?? .files)
            if col >= pcol, col < pcol + width, i >= 0, i < app.overlayItems.count {
                return .overlayRow(i)
            }
            return nil
        }
        guard app.surface == .editor else { return nil }
        if row == L.tabRow {
            var found: AppModel.HoverTarget?
            Scene.forEachTab(app, L) { i, start, width in
                if found == nil, col >= start, col < start + width, i != app.activeIndex {
                    found = .tab(i)
                }
            }
            if found == nil {
                let plus = Scene.newTabCol(app, L)
                if col >= plus, col < plus + Scene.newTabCols { found = .newTab }
            }
            return found
        }
        if row == L.statusRow, app.doc.ioError == nil {
            // Only the segments that DO something answer here — `statusSegment`
            // returns nil for a readout — so the pointer never lights up a fact
            // you cannot change (PLAN.md §5.7).
            if let i = Scene.statusSegment(atCol: col, app, L, limit: statusLimit(L)) {
                return .status(i)
            }
            return nil
        }
        if col < L.railCols, row >= L.railTopRow {
            let i = Scene.railIndex(atRow: row, L)
            if i >= 0, i < Scene.railItems.count, app.overlay != Scene.railItems[i].overlay {
                return .rail(i)
            }
        }
        return nil
    }

    /// Tracking areas over the chrome, and only the chrome. Rebuilt on layout
    /// because the tab row and the rail move with it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        let scale = window?.backingScaleFactor ?? 2
        let m = renderer.atlas.metrics
        let cellW = CGFloat(m.cellWidthPx) / scale, cellH = CGFloat(m.cellHeightPx) / scale
        let ox = CGFloat(m.originX(forWidthPx: Int(metalLayer.drawableSize.width))) / scale
        let oy = CGFloat(m.originY(forHeightPx: Int(metalLayer.drawableSize.height))) / scale
        let L = Scene.EditorLayout(cols: visibleCols, rows: visibleRows,
                                   lineCount: app.doc.buffer.lineCount)
        func rect(cols: Range<Int>, rows: Range<Int>) -> NSRect {
            let top = oy + CGFloat(rows.lowerBound) * cellH
            return NSRect(x: ox + CGFloat(cols.lowerBound) * cellW,
                          y: bounds.height - top - CGFloat(rows.count) * cellH,
                          width: CGFloat(cols.count) * cellW,
                          height: CGFloat(rows.count) * cellH)
        }
        var areas: [NSRect] = []
        if app.overlay != nil {
            areas.append(bounds)                                   // the panel owns the window
        } else if app.surface == .editor {
            areas.append(rect(cols: L.tabCol..<L.cols, rows: L.tabRow..<(L.tabRow + 1)))
            areas.append(rect(cols: 0..<L.railCols, rows: L.railTopRow..<L.statusRow))
            // The status row's left-hand run. §5.7 made two of its segments
            // clickable, and a target with no hover state is a target nobody
            // discovers. The run is bounded by where the HUD begins, so the
            // latency readout is not tracked: it is not a control and never
            // becomes one.
            areas.append(rect(cols: 0..<(L.cols / 2), rows: L.statusRow..<(L.statusRow + 1)))
        }
        for r in areas where r.width > 0 && r.height > 0 {
            addTrackingArea(NSTrackingArea(
                rect: r, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                owner: self, userInfo: nil))
        }
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
    func noteInput(t0: Double, remote: Bool) {
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
    ///
    /// The curve is clamped whenever `|cos(2*pi*t/p)| >= 1/6`, so it *moves*
    /// during the intervals `[edge + k*p/2, p/2 - edge + k*p/2]`. The first
    /// version of this listed `edge, p - edge, p + edge` as the boundaries —
    /// but `p - edge` is where a ramp *ends*, not where one begins, so for a
    /// third of every cycle it promised stillness while the curve was moving
    /// and the caret would have frozen mid-ramp for ~64 ms, over and over.
    /// `--bench-text` samples the prediction against the curve and caught it
    /// with 326 violations; nobody would ever have attributed that stutter to
    /// a timer.
    static func secondsUntilCurveMoves(_ t: Float) -> Double {
        let p = Double(Renderer.caretPeriod)
        let half = p / 2
        // The curve clamps at |cos| >= 1/gain, so that is where a ramp starts
        // and ends. Derived, never a literal: `acos(1.0/6.0)` was correct only
        // for the gain that happened to be in the shader at the time.
        let edge = acos(1.0 / Double(Renderer.caretGain / 2)) / (2 * .pi) * p
        let phase = Double(t).truncatingRemainder(dividingBy: p)
        for k in 0...2 {
            let start = edge + Double(k) * half
            let end = (half - edge) + Double(k) * half
            if phase >= start && phase < end { return 0 }  // already ramping
            if phase < start { return start - phase }
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
        // Finite by rule: `step` reports when nothing is moving and the loop
        // goes back to sleep on the next quiet tick.
        if animator.step(now: now) { dirty = true }
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
                    renderer.rePresentPhases(layer: metalLayer, phase: phases(at: now))
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
                renderer.rePresentPhases(layer: metalLayer, phase: phases(at: monotonicNow()))
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
            phase: phases(at: monotonicNow()),
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
        app.originXPx = renderer.atlas.metrics.originX(forWidthPx: Int(metalLayer.drawableSize.width))
        app.originYPx = renderer.atlas.metrics.originY(forHeightPx: Int(metalLayer.drawableSize.height))
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
