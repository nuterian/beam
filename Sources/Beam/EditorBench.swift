import AppKit
import Foundation
import BeamCore

/// `--bench-editor` — the L2 rows a file view added, measured through the real
/// window event path exactly as `--bench-typing` does (PLAN.md §5.3, §7 "Phase 1").
///
///   open      a generated 1 MB source file, chosen in the open overlay ->
///             the frame carrying its first line PRESENTED.
///   typing    the same paced pass as `--bench-typing`, but into that 1 MB
///             document. Deliberately the SAME budget as the empty-document
///             row: document size must not be visible in typing latency.
///   scroll    sustained full-speed wheel input -> presented, plus the share of
///             display-link ticks that produced no frame.
///   select    a mouse drag extending a selection -> presented.
///   overlay   keystrokes in the open overlay's query, with the real candidate
///             list behind it — the file-tree keystroke cost.
///
/// It needs a visible window (every present-timed bench does), so it classifies
/// its failures the same way: exit 5 if the window was occluded mid-run, exit 6
/// if frames stopped reaching the glass, exit 4 for anything that is genuinely
/// wrong. `scripts/gate.sh` retries only 5 and 6.
final class EditorBench {
    private let view: GridView
    private let window: NSWindow
    private let app: AppModel
    private let outPath: String

    private var openMs = 0.0
    private var typingCommit: [Double] = []
    private var scrollPresented: [Double] = []
    private var selectPresented: [Double] = []
    private var overlayCommitMs: [Double] = []
    private var tabSwitchPresented: [Double] = []
    private var scrollDroppedPct = 0.0
    private var rssMb = 0.0

    private var filePath = ""
    private var lastProgress = monotonicNow()
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?
    private var sawOcclusion = false
    /// Ground truth, not a proxy. `NSWindow.occlusionState` is not a visibility
    /// oracle (PLAN.md §5-L2) and it reported `.visible` on this machine while
    /// a screensaver was dropping most presents — which inflated every number
    /// here by a frame, because a dropped present is re-rendered carrying its
    /// ORIGINAL t0, so the recorded latency correctly includes the drop penalty
    /// and just as correctly is not a measurement of Beam.
    ///
    /// So validity is judged the way the join bench judges it: did presents
    /// actually reach the glass? Below 90% delivery the run refuses to publish.
    /// A genuinely covered window fails loudly; a visible one passes honestly.
    private var presentsOK = 0
    private var presentsDropped = 0

    init(view: GridView, window: NSWindow, app: AppModel, outPath: String) {
        self.view = view
        self.window = window
        self.app = app
        self.outPath = outPath
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .idleDisplaySleepDisabled], reason: "beam editor bench")
        view.recorder.collectAll = true
        view.onProbePresent = { [weak self] presentedTime in
            guard let self else { return }
            if presentedTime > 0 { self.presentsOK += 1 } else { self.presentsDropped += 1 }
        }
        view.recorder.onPresentedSample = { [weak self] _ in self?.lastProgress = monotonicNow() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Every second, not only on a keystroke: the scroll and drag passes
            // send no keys, so an occlusion that began inside one of them would
            // otherwise go unnoticed and the run would PUBLISH fiction. Latency
            // numbers from an occluded window are not numbers.
            if !self.window.occlusionState.contains(.visible) { self.sawOcclusion = true }
            if monotonicNow() - self.lastProgress > 8 {
                FileHandle.standardError.write(
                    "BEAM_PRESENT_STALL: no presented frames for 8 s — the display stopped accepting frames (asleep or occluded); benches need a visible screen\n"
                        .data(using: .utf8)!)
                exit(6)
            }
        }
        guard let path = Self.writeSampleFile() else {
            FileHandle.standardError.write("cannot write the 1 MB sample file\n".data(using: .utf8)!)
            exit(4)
        }
        filePath = path
        // Warm the pipeline before anything is timed.
        runKeys(count: 40, gapMs: 23) { [weak self] in self?.beginOpen() }
    }

    // MARK: - Passes

    /// Opening is measured from the moment the overlay's row is *committed* —
    /// the keystroke a user presses — to the frame carrying the file's first
    /// line on the glass. Everything in between is ours: read, line-index scan,
    /// the highlighter's state pass, instance build, present.
    private func beginOpen() {
        // Seeded directly rather than through `openOverlay`: a real scan runs on
        // a background queue and would race this pass by replacing the items
        // between here and the commit. The overlay's own cost is measured in
        // its own pass, against a real candidate list.
        app.debugSetOverlay(.files, query: "", files: [filePath], selection: 0)
        let t0 = monotonicNow()
        var marked = false
        view.onEditorPresented = { [weak self] presented in
            guard let self, !marked, self.app.doc.path == self.filePath else { return }
            marked = true
            self.openMs = (presented - t0) * 1000
            self.view.onEditorPresented = nil
            self.progressed()
            DispatchQueue.main.async { self.beginTyping() }
        }
        app.overlayCommit()
        view.render(t0: nil)
        // If the present is dropped the render loop recovers on its own; the
        // watchdog is what turns a screen that never comes back into exit 6.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !marked else { return }
            FileHandle.standardError.write("open never reached the glass\n".data(using: .utf8)!)
            exit(6)
        }
    }

    /// Typing into the loaded 1 MB document. The caret is put in the middle of
    /// the file on purpose — typing at offset 0 or at the end would keep the
    /// gap where it already is and hide exactly the cost this is looking for.
    private func beginTyping() {
        let doc = app.doc
        doc.caret = doc.buffer.count / 2
        doc.revealCaret(cellWidthPx: app.cellWidthPx, cellHeightPx: app.cellHeightPx,
                        viewportRows: app.viewportRows, viewportCols: app.viewportCols)
        view.recorder.reset()
        runKeys(count: 300, gapMs: 23) { [weak self] in
            guard let self else { return }
            self.drain {
                self.typingCommit = self.view.recorder.commitSamples
                self.beginScroll()
            }
        }
    }

    /// Full-speed scrolling: precise wheel deltas at ~120 Hz, faster than any
    /// trackpad delivers, for two seconds.
    private func beginScroll() {
        view.recorder.reset()
        app.doc.scrollPx = 0
        let ticksBefore = view.tickCount
        var landed = 0
        view.onEditorPresented = { _ in landed += 1 }
        runScroll(count: 240, gapMs: 8) { [weak self] in
            guard let self else { return }
            // Ticks are counted HERE, before the drain: the 300 ms of quiet
            // that lets in-flight presents land has no input in it, so counting
            // its ticks would report a seventh of a perfectly smooth scroll as
            // dropped frames.
            let ticks = max(1, self.view.tickCount - ticksBefore)
            self.drain {
                self.view.onEditorPresented = nil
                self.scrollPresented = self.view.recorder.presentedSamples
                // Ticks that produced no presented frame, as a percentage. The
                // loop coalesces to the display link by design, so a tick with
                // pending input and no frame is a dropped frame.
                self.scrollDroppedPct = max(0, Double(ticks - landed) / Double(ticks) * 100)
                self.beginTabSwitch()
            }
        }
    }

    /// Switching tabs, by the shortcut, through the real command table. A
    /// second document is opened first so there is something to switch to.
    private func beginTabSwitch() {
        app.openDocument(path: (filePath as NSString).deletingLastPathComponent
                         + "/module_1_render.rs")
        guard app.documents.count > 1 else {
            FileHandle.standardError.write("tab pass: the second document did not open\n".data(using: .utf8)!)
            exit(4)
        }
        view.recorder.reset()
        var left = 60
        func step() {
            guard left > 0 else {
                drain {
                    self.tabSwitchPresented = self.view.recorder.presentedSamples
                    self.beginSelectDrag()
                }
                return
            }
            left -= 1
            send(characters: "]", keyCode: 30, modifiers: [.command, .shift])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.023) { step() }
        }
        step()
    }

    /// A selection drag: mouseDragged events walking down the document, each
    /// extending the selection by a line.
    private func beginSelectDrag() {
        app.doc.scrollPx = 0
        app.doc.placeCaret(at: 0, extend: false)
        view.recorder.reset()
        var step = 0
        func drag() {
            guard step < 200 else {
                drain {
                    self.selectPresented = self.view.recorder.presentedSamples
                    self.beginOverlay()
                }
                return
            }
            let t = ProcessInfo.processInfo.systemUptime
            let row = Scene.EditorLayout(cols: 100, rows: app.viewportRows + 4,
                                         lineCount: app.doc.buffer.lineCount).topRow
                + (step % max(1, app.viewportRows))
            sendDrag(row: row, col: 6 + (step % 40), timestamp: t)
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { drag() }
        }
        // A press first, or there is nothing to extend.
        sendMouseDown(row: Scene.topRow, col: 6)
        drag()
    }

    /// Typing in the open overlay's query, with the real candidate list behind
    /// it. This is the file-tree keystroke cost: filtering runs on the
    /// keystroke path because there is nowhere else to put it.
    private func beginOverlay() {
        sendMouseUp()
        app.openOverlay(.files)
        awaitScan { self.runOverlayPass() }
    }

    /// The scan is deliberately NOT part of this measurement: it happens once,
    /// off the main thread, on first use. What is measured is the per-keystroke
    /// filter over a real candidate list.
    private func awaitScan(_ then: @escaping () -> Void) {
        guard app.fileIndex.didScan || waited > 60 else {
            waited += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.awaitScan(then) }
            return
        }
        then()
    }

    private func runOverlayPass() {
        view.recorder.reset()
        let query = Array("renderer".utf8)
        var i = 0
        func step() {
            guard i < 120 else {
                app.closeOverlay()
                drain {
                    self.overlayCommitMs = self.view.recorder.commitSamples
                    self.finish()
                }
                return
            }
            if i % 8 == 0 { app.closeOverlay(); app.openOverlay(.files) }
            let c = Character(UnicodeScalar(query[i % query.count]))
            sendKey(String(c))
            i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { step() }
        }
        step()
    }

    // MARK: - Plumbing

    /// A generated ~1 MB Rust-ish source file, inside a generated tree of
    /// sibling files.
    ///
    /// Generated rather than shipped so the repository does not carry a
    /// megabyte of filler, and structured rather than random so the highlighter
    /// does real work on it. The **tree** matters as much as the file: the open
    /// overlay scans the directory holding the current document, and the first
    /// version of this bench dropped the sample file straight into
    /// `NSTemporaryDirectory()` — which on this machine held 9,728 files and on
    /// another would hold some other number. A gate whose candidate set depends
    /// on how long the machine has been up is not a gate.
    static let treeFiles = 2_000

    static func writeSampleFile() -> String? {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("beam-bench-tree")
        try? fm.removeItem(atPath: root)
        for d in ["src", "src/render", "docs", "tests"] {
            try? fm.createDirectory(atPath: (root as NSString).appendingPathComponent(d),
                                    withIntermediateDirectories: true)
        }
        let dirs = ["src", "src/render", "docs", "tests"]
        for i in 0..<treeFiles {
            let name = "\(dirs[i % dirs.count])/module_\(i)_render.rs"
            fm.createFile(atPath: (root as NSString).appendingPathComponent(name),
                          contents: Data("// \(i)\n".utf8))
        }

        let path = (root as NSString).appendingPathComponent("src/renderer.rs")
        let unit = """
        /// Encode one frame — the hot path for module %d.
        pub fn render_%d(&mut self, n: usize) -> Result<(), Error> {
            let frame = self.next_frame()?;          // 0xFF is the full alpha
            for i in 0..n {
                frame.push(self.atlas.glyph(i), 0xFF);
            }
            /* a block comment, so the carry state has something to carry */
            Ok(())
        }

        """
        var out = ""
        out.reserveCapacity(1_100_000)
        var i = 0
        while out.utf8.count < 1_000_000 {
            out += String(format: unit, i, i)
            i += 1
        }
        guard (try? out.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        return path
    }

    private func progressed() { lastProgress = monotonicNow() }

    private var sentKeys = 0
    private var waited = 0

    private func send(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if !window.occlusionState.contains(.visible) && !view.assumeVisible { sawOcclusion = true }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else {
            FileHandle.standardError.write("cannot synthesize key event\n".data(using: .utf8)!)
            exit(4)
        }
        window.sendEvent(event)
    }

    private func sendKey(_ c: String? = nil) {
        if !window.occlusionState.contains(.visible) && !view.assumeVisible { sawOcclusion = true }
        sentKeys += 1
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789 "
        let ch = c ?? String(Array(chars)[sentKeys % chars.count])
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0
        ) else {
            FileHandle.standardError.write("cannot synthesize key event\n".data(using: .utf8)!)
            exit(4)
        }
        window.sendEvent(event)
    }

    private func runKeys(count: Int, gapMs: Double, then done: @escaping () -> Void) {
        var left = count
        func step() {
            if left == 0 { done(); return }
            left -= 1
            sendKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + gapMs / 1000) { step() }
        }
        step()
    }

    private func runScroll(count: Int, gapMs: Double, then done: @escaping () -> Void) {
        var left = count
        var down = true
        func step() {
            if left == 0 { done(); return }
            left -= 1
            if left % 60 == 0 { down.toggle() }
            sendScroll(dy: down ? -18 : 18)
            DispatchQueue.main.asyncAfter(deadline: .now() + gapMs / 1000) { step() }
        }
        step()
    }

    /// A precise-delta scroll event. `CGEvent` is the only way to synthesize one
    /// that carries `hasPreciseScrollingDeltas`, which is what a trackpad sends
    /// and therefore what the code path under test has to handle.
    private func sendScroll(dy: Int) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
        // `NSEvent.timestamp` is seconds since boot; `CGEvent.timestamp` is
        // NANOSECONDS since boot, and a freshly created CGEvent carries a raw
        // mach tick count instead — which read back as a t0 four days in the
        // past and produced a 366,811,454 ms "latency". Stamp it in the domain
        // NSEvent will read it in. A real trackpad event needs none of this;
        // this is the cost of synthesizing one.
        cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    private func pointFor(row: Int, col: Int) -> NSPoint {
        let scale = window.backingScaleFactor
        let cellW = CGFloat(view.renderer.atlas.cellWidthPx) / scale
        let cellH = CGFloat(view.renderer.atlas.cellHeightPx) / scale
        let m = view.renderer.atlas.metrics
        let originX = CGFloat(m.originX(forWidthPx: Int(view.bounds.width * scale))) / scale
        let originY = CGFloat(m.originY(forHeightPx: Int(view.bounds.height * scale))) / scale
        let x = originX + (CGFloat(col) + 0.5) * cellW
        let yFromTop = originY + (CGFloat(row) + 0.5) * cellH
        return NSPoint(x: x, y: view.bounds.height - yFromTop)
    }

    private func sendMouse(_ type: NSEvent.EventType, row: Int, col: Int, timestamp: Double? = nil) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: pointFor(row: row, col: col), modifierFlags: [],
            timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }
    private func sendMouseDown(row: Int, col: Int) { sendMouse(.leftMouseDown, row: row, col: col) }
    private func sendDrag(row: Int, col: Int, timestamp: Double) {
        sendMouse(.leftMouseDragged, row: row, col: col, timestamp: timestamp)
    }
    private func sendMouseUp() { sendMouse(.leftMouseUp, row: Scene.topRow, col: 6) }

    private func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    private func drain(_ done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
    }

    // MARK: - Results

    private func finish() {
        watchdog?.invalidate()
        let total = presentsOK + presentsDropped
        let delivered = total > 0 ? Double(presentsOK) / Double(total) : 0
        if sawOcclusion || delivered < 0.9 {
            FileHandle.standardError.write(String(
                format: "editor bench INVALID: only %.0f%% of presents reached the glass (%d of %d)%@ — an occluded or asleep screen drops presents and every number here would be fiction\n",
                delivered * 100, presentsOK, total,
                sawOcclusion ? ", and the window reported itself occluded" : "")
                .data(using: .utf8)!)
            exit(5)
        }
        // A sample larger than a second is not a latency, it is a broken clock
        // domain. Refuse to publish rather than gate on garbage.
        for (name, samples) in [("scroll", scrollPresented), ("select", selectPresented),
                                ("typing", typingCommit), ("overlay", overlayCommitMs),
                                ("tab switch", tabSwitchPresented)] {
            if let bad = samples.first(where: { $0 > 1000 || $0 < 0 }) {
                FileHandle.standardError.write(
                    "editor bench INVALID: \(name) produced a \(bad) ms sample — that is a clock-domain bug, not a latency\n"
                        .data(using: .utf8)!)
                exit(4)
            }
        }
        guard !typingCommit.isEmpty, scrollPresented.count >= 20, !selectPresented.isEmpty,
              !overlayCommitMs.isEmpty, !tabSwitchPresented.isEmpty else {
            FileHandle.standardError.write(
                "editor bench: thin pass (typing=\(typingCommit.count) scroll=\(scrollPresented.count) select=\(selectPresented.count) overlay=\(overlayCommitMs.count) tabs=\(tabSwitchPresented.count)) — too few presents landed to publish\n"
                    .data(using: .utf8)!)
            exit(4)
        }
        rssMb = currentRSSMB()
        let typing = summarize(typingCommit)
        let scroll = summarize(scrollPresented)
        let select = summarize(selectPresented)
        let overlay = summarize(overlayCommitMs)
        let tabs = summarize(tabSwitchPresented)
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        let suffix = fps >= 100 ? "120hz" : "60hz"

        print(String(format: "open 1 MB file -> first paint: %.1f ms  (%d lines)",
                     openMs, app.doc.buffer.lineCount))
        print(String(format: "typing in 1 MB doc  n=%d: commit p50 %.2f  p99 %.2f ms",
                     typingCommit.count, typing.p50, typing.p99))
        print(String(format: "scroll -> presented n=%d: p50 %.2f  p99 %.2f ms   dropped %.2f%% of ticks",
                     scrollPresented.count, scroll.p50, scroll.p99, scrollDroppedPct))
        print(String(format: "select drag         n=%d: p50 %.2f  p99 %.2f ms",
                     selectPresented.count, select.p50, select.p99))
        print(String(format: "tab switch          n=%d: p50 %.2f  p99 %.2f ms  (%d tabs)",
                     tabSwitchPresented.count, tabs.p50, tabs.p99, app.documents.count))
        print(String(format: "overlay keystroke   n=%d: commit p50 %.2f  p99 %.2f ms  (%d candidates)",
                     overlayCommitMs.count, overlay.p50, overlay.p99, app.fileIndex.paths.count))
        if app.fileIndex.paths.count < Self.treeFiles {
            // The candidate set is the point of this row; a short one means the
            // scan did not finish and the number understates the real cost.
            FileHandle.standardError.write(
                "editor bench INVALID: the overlay filtered only \(app.fileIndex.paths.count) candidates, expected \(Self.treeFiles + 1)\n"
                    .data(using: .utf8)!)
            exit(4)
        }
        print(String(format: "RSS with the file open: %.1f MB", rssMb))
        print(String(format: "presents delivered: %.1f%% (%d of %d)", delivered * 100, presentsOK, total))
        print("draw calls per frame: \(view.renderer.drawCallsLastFrame)")

        do {
            try writeResult(to: outPath, metrics: [
                "L2_local_render.open_1mb_file_to_first_paint_ms": openMs,
                "L2_local_render.keystroke_to_commit_1mb_doc_p99_ms": typing.p99,
                "L2_local_render.scroll_wheel_to_presented_\(suffix)_p99_ms": scroll.p99,
                "L2_local_render.scroll_dropped_frames_pct": scrollDroppedPct,
                "L2_local_render.selection_drag_to_presented_\(suffix)_p99_ms": select.p99,
                "L2_local_render.tab_switch_to_presented_\(suffix)_p99_ms": tabs.p99,
                "L2_local_render.overlay_keystroke_to_commit_p99_ms": overlay.p99,
                "L7_steady_state.rss_with_1mb_file_mb": rssMb,
            ])
        } catch {
            FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
        exit(0)
    }
}
