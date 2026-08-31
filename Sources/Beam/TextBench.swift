import Foundation
import BeamCore

/// `--bench-text` — the headless half of Phase 1, in the same spirit as
/// `--verify-session` is for Phase 2: it needs no window, no display and no
/// screen, so it runs on a shared CI runner and it cannot be aborted by this
/// machine's screensaver.
///
/// It does two jobs, and the first one is the more important. **Correctness
/// first:** the gap buffer's raw-coordinate line index is the load-bearing idea
/// in PLAN.md §5.3, and an index that silently disagrees with the bytes would
/// corrupt a file rather than fail a benchmark — so it is fuzzed against a dumb
/// reference model and an exhaustive rescan, and a mismatch exits 4 (a real
/// failure, never retried into a pass). **Then the micro-budgets** that have
/// nowhere else to be measured: undo at depth, one line of lexing, one atlas
/// miss.
enum TextBench {
    static func run(outPath: String) -> Never {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what) }
        }

        // MARK: Correctness — the buffer against a reference model

        var rng = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = Array("abc \n{}\"/*é→".utf8)
        for trial in 0..<200 {
            let buf = TextBuffer()
            var model: [UInt8] = []
            for _ in 0..<120 {
                if !model.isEmpty && Int.random(in: 0..<3, using: &rng) == 0 {
                    let lo = Int.random(in: 0..<model.count, using: &rng)
                    let hi = min(model.count, lo + Int.random(in: 1...4, using: &rng))
                    _ = buf.remove(lo..<hi)
                    model.removeSubrange(lo..<hi)
                } else {
                    let at = model.isEmpty ? 0 : Int.random(in: 0...model.count, using: &rng)
                    let n = Int.random(in: 1...5, using: &rng)
                    var bytes: [UInt8] = []
                    for _ in 0..<n { bytes.append(alphabet.randomElement(using: &rng)!) }
                    _ = buf.insert(bytes, at: at)
                    model.insert(contentsOf: bytes, at: at)
                }
            }
            if buf.bytes(in: 0..<buf.count) != model { failures.append("trial \(trial): bytes diverged"); break }
            if !buf.indexMatchesScan() { failures.append("trial \(trial): line index diverged from a full rescan"); break }
            let expectedLines = model.filter { $0 == 0x0A }.count + 1
            if buf.lineCount != expectedLines { failures.append("trial \(trial): lineCount \(buf.lineCount) != \(expectedLines)"); break }
            // Every line's range must reconstruct the model exactly.
            var rebuilt: [UInt8] = []
            for l in 0..<buf.lineCount {
                rebuilt.append(contentsOf: buf.bytes(in: buf.lineRange(l)))
                if l < buf.lineCount - 1 { rebuilt.append(0x0A) }
            }
            if rebuilt != model { failures.append("trial \(trial): lineRange did not reconstruct the document"); break }
            // And every offset must round-trip through (line, column).
            var roundTripOK = true
            for o in stride(from: 0, through: model.count, by: max(1, model.count / 17)) {
                let p = buf.position(ofOffset: o)
                if buf.offset(line: p.line, byteColumn: p.byteColumn) != o { roundTripOK = false; break }
            }
            check(roundTripOK, "trial \(trial): offset -> (line, column) -> offset did not round-trip")
            if !failures.isEmpty { break }
        }

        // MARK: Correctness — UTF-8 does not get cut in half

        do {
            let doc = Document()
            _ = doc.insert(Array("héllo→wörld".utf8))
            check(doc.buffer.wholeText == "héllo→wörld", "multibyte insert round trip")
            doc.caret = doc.buffer.count
            _ = doc.deleteBackward()
            check(doc.buffer.wholeText == "héllo→wörl", "backspace deleted a whole scalar, not a byte")
            doc.caret = 3   // just past 'é', which occupies bytes 1...2
            _ = doc.deleteBackward()
            check(doc.buffer.wholeText == "hllo→wörl",
                  "backspace over a 2-byte scalar removes both its bytes (got \(doc.buffer.wholeText))")
            // Column mapping: a tab is four cells, a multibyte scalar is one.
            let doc2 = Document()
            _ = doc2.insert(Array("\té→x".utf8))
            check(doc2.cellColumn(ofOffset: doc2.buffer.count) == 4 + 3,
                  "tab expands to 4 cells and each scalar is 1 (got \(doc2.cellColumn(ofOffset: doc2.buffer.count)))")
            check(doc2.offset(line: 0, cellColumn: 4) == 1, "cell column -> offset lands after the tab")
        }

        // MARK: Correctness — undo puts the document back, exactly

        do {
            let doc = Document()
            _ = doc.insert(Array("fn main() {\n    println!(\"hi\");\n}".utf8))
            let original = doc.buffer.wholeText
            // Loading a document is not an edit — `open()` clears the stack for
            // exactly this reason, and undoing past the file you opened would
            // hand you an empty buffer.
            doc.undo.clear()
            doc.caret = 12
            for b in Array("let x = 1;".utf8) { _ = doc.insert([b]) }
            _ = doc.insert(Array("\n".utf8))
            doc.caret = 5
            _ = doc.deleteForward()
            var steps = 0
            while doc.applyUndo() { steps += 1; if steps > 100 { break } }
            check(doc.buffer.wholeText == original,
                  "undo to the bottom restored the file as opened (got \(doc.buffer.wholeText.debugDescription))")
            check(doc.buffer.indexMatchesScan(), "line index survived undo")
            var redos = 0
            while doc.applyRedo() { redos += 1; if redos > 100 { break } }
            check(redos == steps, "redo replayed every step (\(redos) vs \(steps))")
            check(doc.buffer.indexMatchesScan(), "line index survived redo")
            // Coalescing: ten typed characters must not be ten undo steps.
            let doc2 = Document()
            for b in Array("hello".utf8) { _ = doc2.insert([b]) }
            check(doc2.undo.count == 1, "five typed characters coalesced into one undo step (got \(doc2.undo.count))")
        }

        // MARK: Correctness — the lexer colours what it should

        do {
            let doc = Document()
            _ = doc.insert(Array("let n: Int = 42  // note\nfoo(\"s\")\n/* a\nb */ x\n".utf8))
            doc.highlighter.reset(language: .swift, buffer: doc.buffer)
            let l0 = doc.highlighter.tokens(line: 0, buffer: doc.buffer)
            check(l0.contains { $0.kind == .keyword && $0.start == 0 }, "`let` is a keyword")
            check(l0.contains { $0.kind == .type }, "`Int` is a type")
            check(l0.contains { $0.kind == .number }, "`42` is a number")
            check(l0.contains { $0.kind == .comment }, "`// note` is a comment")
            let l1 = doc.highlighter.tokens(line: 1, buffer: doc.buffer)
            check(l1.contains { $0.kind == .function }, "`foo(` is a call")
            check(l1.contains { $0.kind == .string }, "`\"s\"` is a string")
            // The block comment's carry state must reach line 3.
            let l3 = doc.highlighter.tokens(line: 3, buffer: doc.buffer)
            check(l3.contains { $0.kind == .comment && $0.start == 0 },
                  "a block comment opened on line 2 is still a comment on line 3")
            check(!l3.contains { $0.kind == .comment && $0.end > 4 },
                  "and it stops at its close delimiter")
        }

        // MARK: Correctness — the shell, without a window

        do {
            let app = AppModel(localName: "bench-0000")
            app.debugOpen(text: "alpha\nbeta\ngamma", name: "x.swift")
            app.debugSetPeers(["marlowe-air-1180", "atlas-mini-9042"])

            // The peer overlay's rows must be the peers, numbered from 1 — that
            // numbering IS §5.1's join gesture, one layer in.
            app.debugSetOverlay(.peers, query: "", files: [], selection: 0)
            check(app.overlayItems.count == 2, "the peer overlay lists both peers")
            check(app.overlayItems.first?.number == 1 && app.overlayItems.first?.peerIndex == 0,
                  "the first peer is '1' and joins peer 0")

            // Alone and denied are designed paragraphs, never a blank list.
            let quiet = AppModel(localName: "bench-0001")
            quiet.debugSetOverlay(.peers, query: "", files: [], selection: 0)
            check(quiet.overlayItems.isEmpty && quiet.overlayEmptyLines.count == 2,
                  "alone on the network is a two-line designed state")
            let denied = AppModel(localName: "bench-0002")
            denied.debugSetPresence(.localNetworkDenied)
            denied.debugSetOverlay(.peers, query: "", files: [], selection: 0)
            check(denied.overlayEmptyLines.first?.1 == .red,
                  "a permission denial is red, and never reads as an empty network")
            check(denied.overlayEmptyLines.contains { $0.0.contains("system settings") },
                  "and it names the exact Settings path")
            // §2: it must also be on the glass without opening anything.
            check(Scene.presenceSpans(denied, now: 10).contains { $0.ink == .red },
                  "the status line says so too, so a denial cannot hide behind a keypress")

            // Every designed empty state has to fit inside the panel, or it
            // spills onto the scrim — which --dump-scene caught once already.
            let room = Scene.overlayWidth - 4
            for m in [quiet, denied] {
                for line in m.overlayEmptyLines {
                    check(line.0.count <= room,
                          "\"\(line.0)\" (\(line.0.count)) fits the \(Scene.overlayWidth)-cell panel")
                }
            }
        }

        // MARK: Correctness — a remote edit moves the local caret with the text

        do {
            let app = AppModel(localName: "bench-0003")
            app.debugOpen(text: "abcdef", name: "x.txt")
            app.debugSetRemote(offset: 0, peer: "peer-1")
            app.doc.caret = 4
            app.debugApplyRemoteInsert(byte: UInt8(ascii: "Z"))
            check(app.doc.buffer.wholeText == "Zabcdef", "a remote insert lands at the sender's caret")
            check(app.doc.caret == 5, "and the local caret, which was after it, moved with the text (got \(app.doc.caret))")
            app.doc.caret = 0
            app.debugApplyRemoteInsert(byte: UInt8(ascii: "Y"))
            check(app.doc.caret == 0, "a caret before the edit does not move (got \(app.doc.caret))")
            check(app.remote?.offset == 2, "the remote caret advanced past its own insert")
        }

        // MARK: Correctness — the caret's sleep prediction matches its own curve

        do {
            // The blink pauses the display link and sets an alarm for the next
            // moment the curve moves. If that prediction disagrees with the
            // curve the shader actually draws, the caret freezes mid-pulse or
            // jumps — a defect nobody would attribute to a timer. So the two
            // are checked against each other rather than trusted to stay in
            // step (PLAN.md §5.5).
            let period = Double(Renderer.caretPeriod)
            var flatViolations = 0
            var everMoves = false
            var t = 0.0
            while t < period * 2 {
                let rest = GridView.secondsUntilCurveMoves(Float(t))
                let a0 = GridView.caretAlpha(Float(t))
                if rest > 0.01 {
                    // It claims the curve is still for `rest` seconds. Sample it.
                    var u = 0.0
                    while u < rest {
                        if abs(GridView.caretAlpha(Float(t + u)) - a0) > 1.0 / 255 { flatViolations += 1; break }
                        u += 0.004
                    }
                } else {
                    everMoves = true
                }
                t += 0.004
            }
            check(flatViolations == 0,
                  "the caret's sleep prediction never claims stillness while the curve is moving (\(flatViolations) violations)")
            check(everMoves, "and it does not claim the curve is always still")
            // The shape itself: fully on at the top, near the floor at the
            // bottom, and a ramp short enough to read as a blink.
            check(GridView.caretAlpha(0) > 0.99, "the pulse rests fully on")
            check(GridView.caretAlpha(Float(period / 2)) < 0.2, "and dips to its floor")
            check(GridView.caretAlpha(Float(period / 2)) > 0.05,
                  "but never to nothing — a caret you cannot find is worse than one that does not blink")
            check(GridView.caretAlpha(-1) == 1, "a negative time means rest solid")
        }

        // MARK: Correctness — the cell stays 1:2 at every zoom step

        do {
            // **The invariant every shape glyph in Beam is built on** (PLAN.md
            // §5.7). The rail icons are square paths drawn across two cells
            // because a cell is half a square; the join code's block pixels are
            // square as `2s` cells by `s` rows, on the one screen where the
            // security model is a human comparing digits. Under the old rule —
            // a designed line height as the *input* — only four of thirteen
            // sizes held it, so a zoom control would have broken the rail, the
            // caret and the join code at nine steps in thirteen, silently,
            // because nothing asserted it. This is that assertion.
            //
            // Headless by construction: `Metrics` is CoreText only, no Metal
            // and no window, which is the same seam `--dump-scene` uses.
            for pt in Zoom.steps {
                let m = GlyphAtlas.Metrics(pointSize: pt, scale: 2)
                check(m.cellHeightPx == 2 * m.cellWidthPx,
                      "the cell is 1:2 at \(pt) pt (got \(m.cellWidthPx)x\(m.cellHeightPx))")
                // §5.2's rule, which the derivation does not get to repeal: the
                // cell must clear the font's real ink, and the baseline must
                // leave room for the deepest descender.
                check(m.baselinePx > 0 && m.baselinePx < m.cellHeightPx,
                      "the baseline is inside the cell at \(pt) pt")
                let lh = GlyphAtlas.lineHeightEm(m, pointSize: pt)
                check(lh > 1.18 && lh < 1.36,
                      "the implied line height at \(pt) pt stays inside the band §5.2 designed in (got \(lh))")
            }
            check(Zoom.steps[Zoom.defaultIndex] == 14, "the default step is the size §5.2 designed at")
            let shipping = GlyphAtlas.Metrics(pointSize: Zoom.defaultPointSize, scale: 2)
            check(shipping.cellWidthPx == 18 && shipping.cellHeightPx == 36 && shipping.baselinePx == 29,
                  "and deriving the cell did not move the shipping one (got \(shipping.cellWidthPx)x\(shipping.cellHeightPx), baseline \(shipping.baselinePx))")
        }

        // MARK: - The open overlay's ranking (PLAN.md §5.8)
        //
        // **Asserted here, and not only in Tests/, on purpose.** This exact
        // expectation had been in `Tests/BeamCoreTests` the whole time and had
        // never once run: SwiftPM is broken on the dev machine, so `swift test`
        // only started executing when CI did — and it immediately found that
        // typing `rend` ranked `docs/rendering.md` above `src/renderer.rs`,
        // because a single greedy scan let the `r` in `src` eat the query's
        // first character. A correctness claim that lives only where nobody
        // runs it is not a claim.
        do {
            let dir = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("beam-rank-\(getpid())")
            let fm = FileManager.default
            try? fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("src"),
                                    withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("docs"),
                                    withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            for p in ["src/renderer.rs", "src/render_loop.rs", "docs/rendering.md", "unrelated.txt"] {
                fm.createFile(atPath: (dir as NSString).appendingPathComponent(p),
                              contents: Data("x".utf8))
            }
            let index = FileIndex()
            index.scan(root: dir)
            let hits = index.filter("rend", limit: 10).map { index.paths[$0] }
            check(hits.first == "src/renderer.rs",
                  "the file finder ranks a segment-start match first (got \(hits.first ?? "nothing"))")
            check(!hits.contains("unrelated.txt"), "and a non-match never appears")
            check(index.filter("zzzz", limit: 10).isEmpty, "and a query matching nothing returns nothing")
        }

        // MARK: - Find's scan, in isolation (PLAN.md §5.8)
        //
        // `find_keystroke_to_commit_p99_ms` measured 9.25 ms p50 against a 4 ms
        // budget, with p50 and p99 within 0.2 ms of each other — a flat
        // distribution, which is the signature of a constant cost rather than
        // of a loaded machine. This isolates it: same process, same run, same
        // machine as the other micro-benchmarks above, so it can be read
        // RELATIVE to them even when the machine is busy.
        var findScanUs: [Double] = []
        do {
            var text = ""
            text.reserveCapacity(1_100_000)
            let unit = """
            pub fn render_frame(&mut self, n: usize) -> Result<(), Error> {
                let frame = self.next_frame()?;
                for i in 0..n { frame.push(self.atlas.glyph(i), 0xFF); }
                Ok(())
            }

            """
            while text.utf8.count < 1_000_000 { text += unit }
            let buf = TextBuffer(bytes: Array(text.utf8))
            // Both ends of the range a real query covers: one byte (tens of
            // thousands of hits) and five (a handful).
            for q in ["f", "frame"] {
                var find = FindState()
                for _ in 0..<20 {
                    let t = monotonicNow()
                    find.setQuery(Array(q.utf8), buffer: buf, caret: 0)
                    findScanUs.append((monotonicNow() - t) * 1_000_000)
                }
                check(find.count > 0, "the find fixture has matches for \(q)")
            }
        }

        // MARK: - The data-loss guards (PLAN.md §5.8)
        //
        // Headless, in the suite that always runs, because this is the one
        // class of bug where a regression is not a slow frame but somebody's
        // work. Every assertion below is about a path that ENDS in a write.
        do {
            let dir = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("beam-disk-guard-\(getpid())")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let path = (dir as NSString).appendingPathComponent("guard.txt")

            func write(_ text: String) {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
            }

            write("theirs\n")
            let d = Document()
            check(d.open(path: path), "the guard fixture opens")
            check(d.diskState == .unchanged, "a freshly opened document agrees with the disk")

            // An edit here, a write there. The whole point.
            d.perform(Edit(offset: 0, removed: [], inserted: Array("mine ".utf8)))
            check(d.isModified, "an edit marks the document modified")
            // The modification date has a filesystem's resolution, so a write
            // in the same instant can carry the same timestamp. The SIZE moves
            // too, which is exactly why identity is the pair and not the date.
            write("theirs, rewritten by somebody else\n")
            check(d.diskState == .modified, "a write by somebody else is seen")

            check(!d.save(), "save REFUSES when the file changed underneath it")
            check(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data(),
                         as: UTF8.self) == "theirs, rewritten by somebody else\n",
                  "and the refusal left their bytes on disk untouched")

            // The answer that cannot lose anything.
            let copy = d.saveCopyBesideOriginal()
            check(copy != nil, "keep-both writes a copy")
            if let copy {
                check(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: copy))) ?? Data(),
                             as: UTF8.self).hasPrefix("mine "),
                      "the copy holds OUR version")
                check(d.path == path, "and the document keeps the path the user opened, not the rescue's")
            }
            check(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data(),
                         as: UTF8.self) == "theirs, rewritten by somebody else\n",
                  "keep-both left the original alone")

            // Forcing is the only way past, and it re-stamps so the next save
            // is ordinary again.
            check(d.save(force: true), "an explicit overwrite goes through")
            check(d.diskState == .unchanged, "and re-stamps, so the next save asks nothing")
            check(!d.isModified, "a successful save clears the modified flag")
            check(d.save(), "an ordinary save after that needs no force")

            // Reverting is the other half of the answer.
            write("theirs again\n")
            d.perform(Edit(offset: 0, removed: [], inserted: Array("x".utf8)))
            check(d.revert(), "revert re-reads the file")
            check(String(decoding: Data(d.buffer.bytes(in: 0..<d.buffer.count)), as: UTF8.self)
                    == "theirs again\n", "and the buffer is now what is on disk")
            check(!d.isModified && d.diskState == .unchanged, "and the document agrees with the disk again")

            // A document that has never been saved has no disk to conflict
            // with, and must not be dragged through any of this.
            let untitled = Document()
            check(untitled.diskState == .untracked, "an untitled document is untracked")
            check(!untitled.save(), "and cannot be saved, because it has no path")

            // Deletion is its own state: it is NOT 'unchanged', and a save that
            // treated it as unchanged would silently recreate a file the user
            // deleted on purpose without ever saying so.
            let gone = Document()
            write("here\n")
            check(gone.open(path: path), "a second document opens the fixture")
            try? FileManager.default.removeItem(atPath: path)
            check(gone.diskState == .deleted, "a deleted file reads as deleted, not as unchanged")
        }

        if !failures.isEmpty {
            FileHandle.standardError.write(
                ("text bench FAILED:\n  " + failures.joined(separator: "\n  ") + "\n").data(using: .utf8)!)
            exit(4)
        }
        print("correctness: 12 groups pass (buffer fuzz, utf-8, undo/redo, coalescing, columns, lexer, shell states, remote edits, caret curve, the 1:2 cell at every zoom step, the disk guards, file-finder ranking)")

        // MARK: - Micro-budgets

        // Undo at depth: 10k records on the stack, then time one step. Depth
        // must not be visible in the cost of a step.
        let deep = Document()
        _ = deep.insert(Array(repeating: UInt8(ascii: "x"), count: 20_000))
        deep.caret = 10_000
        for _ in 0..<10_000 {
            deep.undo.breakCoalescing()          // one record per keystroke, no merging
            _ = deep.insert([UInt8(ascii: "y")])
        }
        var undoUs: [Double] = []
        for _ in 0..<2_000 {
            let t = monotonicNow()
            _ = deep.applyUndo()
            undoUs.append((monotonicNow() - t) * 1_000_000)
        }
        let undoStats = summarize(undoUs)

        // One line of real source, lexed.
        let source = Array("""
        pub fn render(&mut self, n: usize) -> Result<(), Error> { let frame = self.next_frame()?; }
        """.utf8)
        var spans: [TokenSpan] = []
        var lexUs: [Double] = []
        source.withUnsafeBufferPointer { line in
            for _ in 0..<50 { _ = Lexer.lex(line, from: .normal, .rust, into: &spans) }   // warm
            for _ in 0..<5_000 {
                let t = monotonicNow()
                _ = Lexer.lex(line, from: .normal, .rust, into: &spans)
                lexUs.append((monotonicNow() - t) * 1_000_000)
            }
        }
        let lexStats = summarize(lexUs)

        // One atlas miss: CoreText rasterization of a scalar the atlas has not
        // seen, into one cell, cascade lookup included.
        var missUs: [Double] = []
        if let renderer = try? Renderer(pointSize: Zoom.defaultPointSize, scale: 2) {
            var scalars: [UnicodeScalar] = []
            for v in 0x00C0...0x024F { if let s = UnicodeScalar(UInt32(v)) { scalars.append(s) } }
            for v in 0x2190...0x22FF { if let s = UnicodeScalar(UInt32(v)) { scalars.append(s) } }
            for (i, s) in scalars.enumerated() {
                let slot = GlyphAtlas.firstDynamicSlot + (i % 100)
                let t = monotonicNow()
                _ = renderer.atlas.rasterize(s, into: slot)
                missUs.append((monotonicNow() - t) * 1_000_000)
            }
            missUs.removeFirst(min(20, missUs.count))   // first few pay CoreText's own warm-up
        }
        let missStats = summarize(missUs.isEmpty ? [0] : missUs)

        // Diagnostic, not a gate: the overlay's per-keystroke cost is gated end
        // to end by `overlay_keystroke_to_commit_p99_ms` in --bench-editor, and
        // this is the part of it that is the filter, so a regression there can
        // be attributed instead of guessed at.
        var filterUs: [Double] = []
        let index = FileIndex()
        index.scan(root: FileManager.default.currentDirectoryPath)
        for q in ["r", "re", "ren", "rend", "render"] {
            for _ in 0..<200 {
                let t = monotonicNow()
                _ = index.filter(q, limit: Scene.overlayMaxRows)
                filterUs.append((monotonicNow() - t) * 1_000_000)
            }
        }
        let filterStats = summarize(filterUs)
        print(String(format: "overlay filter    n=%d: p50 %.1f  p99 %.1f  max %.1f us  (%d candidates, diagnostic only)",
                     filterUs.count, filterStats.p50, filterStats.p99, filterStats.max, index.paths.count))

        print(String(format: "undo @10k depth   n=%d: p50 %.1f  p99 %.1f  max %.1f us",
                     undoUs.count, undoStats.p50, undoStats.p99, undoStats.max))
        print(String(format: "lex one line      n=%d: p50 %.1f  p99 %.1f  max %.1f us",
                     lexUs.count, lexStats.p50, lexStats.p99, lexStats.max))
        print(String(format: "find scan 1 MB    n=%d: p50 %.1f  p99 %.1f  max %.1f us  (diagnostic)",
                     findScanUs.count, percentile(findScanUs, 50), percentile(findScanUs, 99),
                     findScanUs.max() ?? 0))
        print(String(format: "atlas miss        n=%d: p50 %.1f  p99 %.1f  max %.1f us",
                     missUs.count, missStats.p50, missStats.p99, missStats.max))

        do {
            try writeResult(to: outPath, metrics: [
                "L2_local_render.undo_10k_depth_p99_us": undoStats.p99,
                "L2_local_render.syntax_highlight_line_p99_us": lexStats.p99,
                "L2_local_render.atlas_miss_rasterize_p99_us": missStats.p99,
            ])
        } catch {
            FileHandle.standardError.write("cannot write results: \(error)\n".data(using: .utf8)!)
            exit(4)
        }
        exit(0)
    }
}
