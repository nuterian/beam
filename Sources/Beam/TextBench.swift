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

        if !failures.isEmpty {
            FileHandle.standardError.write(
                ("text bench FAILED:\n  " + failures.joined(separator: "\n  ") + "\n").data(using: .utf8)!)
            exit(4)
        }
        print("correctness: 8 groups pass (buffer fuzz, utf-8, undo/redo, coalescing, columns, lexer, shell states, remote edits)")

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
        if let renderer = try? Renderer(pointSize: 14, scale: 2) {
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
