import XCTest
@testable import BeamCore

/// The gap buffer's raw-coordinate line index is the load-bearing idea in
/// PLAN.md §5.3, and an index that quietly disagrees with the bytes corrupts a
/// file rather than failing a benchmark. These run in CI (which has SwiftPM);
/// `beam --bench-text` runs the same shape of checks locally and in the gate,
/// because the local toolchain cannot build a test target.
final class TextBufferTests: XCTestCase {

    func testInsertAndLineIndexAgreeWithAFullRescan() {
        let buf = TextBuffer()
        _ = buf.insert(Array("one\ntwo\nthree".utf8), at: 0)
        XCTAssertEqual(buf.lineCount, 3)
        XCTAssertEqual(buf.string(in: buf.lineRange(1)), "two")
        XCTAssertTrue(buf.indexMatchesScan())
    }

    /// The whole point of raw coordinates: typing must not touch the index.
    func testTypingFarFromTheGapKeepsTheIndexValid() {
        let buf = TextBuffer(bytes: Array(repeating: UInt8(ascii: "\n"), count: 5_000))
        XCTAssertEqual(buf.lineCount, 5_001)
        for i in 0..<200 {
            _ = buf.insert([UInt8(ascii: "x")], at: 2_500 + i)
        }
        XCTAssertEqual(buf.lineCount, 5_001)
        XCTAssertTrue(buf.indexMatchesScan())
    }

    func testGapMovesBothWaysWithoutLosingBytes() {
        let buf = TextBuffer(bytes: Array("abcdef\nghijkl\nmnopqr".utf8))
        for at in [0, 20, 3, 18, 7, 1] {
            _ = buf.insert([UInt8(ascii: "*")], at: at)
            XCTAssertTrue(buf.indexMatchesScan(), "index broke after inserting at \(at)")
        }
        XCTAssertEqual(buf.wholeText.filter { $0 == "*" }.count, 6)
    }

    func testRemoveAcrossLinesDropsExactlyTheNewlinesItSwallowed() {
        let buf = TextBuffer(bytes: Array("a\nb\nc\nd".utf8))
        XCTAssertEqual(buf.lineCount, 4)
        _ = buf.remove(1..<5)              // "\nb\nc" -> two newlines gone
        XCTAssertEqual(buf.wholeText, "a\nd")
        XCTAssertEqual(buf.lineCount, 2)
        XCTAssertTrue(buf.indexMatchesScan())
    }

    func testRandomEditsMatchAReferenceModel() {
        var rng = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = Array("ab \n{}é".utf8)
        for _ in 0..<60 {
            let buf = TextBuffer()
            var model: [UInt8] = []
            for _ in 0..<150 {
                if !model.isEmpty, Int.random(in: 0..<3, using: &rng) == 0 {
                    let lo = Int.random(in: 0..<model.count, using: &rng)
                    let hi = min(model.count, lo + Int.random(in: 1...4, using: &rng))
                    _ = buf.remove(lo..<hi)
                    model.removeSubrange(lo..<hi)
                } else {
                    let at = model.isEmpty ? 0 : Int.random(in: 0...model.count, using: &rng)
                    let bytes = (0..<Int.random(in: 1...5, using: &rng))
                        .map { _ in alphabet.randomElement(using: &rng)! }
                    _ = buf.insert(bytes, at: at)
                    model.insert(contentsOf: bytes, at: at)
                }
            }
            XCTAssertEqual(buf.bytes(in: 0..<buf.count), model)
            XCTAssertTrue(buf.indexMatchesScan())
            XCTAssertEqual(buf.lineCount, model.filter { $0 == 0x0A }.count + 1)
        }
    }
}

final class DocumentTests: XCTestCase {

    func testBackspaceRemovesAWholeScalarNotAByte() {
        let doc = Document()
        _ = doc.insert(Array("aéb".utf8))
        doc.caret = doc.buffer.count - 1        // between é and b
        _ = doc.deleteBackward()
        XCTAssertEqual(doc.buffer.wholeText, "ab")
    }

    func testTabsAndMultibyteMapToCellColumns() {
        let doc = Document()
        _ = doc.insert(Array("\té→x".utf8))
        XCTAssertEqual(doc.cellColumn(ofOffset: doc.buffer.count), Document.tabWidth + 3)
        XCTAssertEqual(doc.offset(line: 0, cellColumn: Document.tabWidth), 1)
    }

    func testUndoRestoresTextAndCaret() {
        let doc = Document()
        _ = doc.insert(Array("hello world".utf8))
        doc.undo.clear()
        doc.caret = 5
        for b in Array(", there".utf8) { _ = doc.insert([b]) }
        XCTAssertEqual(doc.undo.count, 1, "typed characters coalesce into one step")
        XCTAssertTrue(doc.applyUndo())
        XCTAssertEqual(doc.buffer.wholeText, "hello world")
        XCTAssertEqual(doc.caret, 5)
        XCTAssertTrue(doc.applyRedo())
        XCTAssertEqual(doc.buffer.wholeText, "hello, there world")
    }

    func testEditIsItsOwnInverse() {
        let e = Edit(offset: 3, removed: Array("ab".utf8), inserted: Array("xyz".utf8))
        XCTAssertEqual(e.inverse.inverse, e)
    }
}

final class LexerTests: XCTestCase {

    private func spans(_ source: String, _ lang: Language, line: Int) -> [TokenSpan] {
        let doc = Document()
        _ = doc.insert(Array(source.utf8))
        doc.highlighter.reset(language: lang, buffer: doc.buffer)
        return doc.highlighter.tokens(line: line, buffer: doc.buffer)
    }

    func testKeywordsTypesNumbersAndComments() {
        let s = spans("let n: Int = 42  // note", .swift, line: 0)
        XCTAssertTrue(s.contains { $0.kind == .keyword && $0.start == 0 })
        XCTAssertTrue(s.contains { $0.kind == .type })
        XCTAssertTrue(s.contains { $0.kind == .number })
        XCTAssertTrue(s.contains { $0.kind == .comment })
    }

    func testBlockCommentCarriesAcrossLinesAndStops() {
        let source = "a\n/* open\nstill\nclosed */ tail\nb"
        XCTAssertTrue(spans(source, .c, line: 2).contains { $0.kind == .comment && $0.start == 0 })
        let closing = spans(source, .c, line: 3)
        XCTAssertTrue(closing.contains { $0.kind == .comment && $0.start == 0 })
        XCTAssertFalse(closing.contains { $0.kind == .comment && $0.end > 9 },
                       "the comment must end at its close delimiter")
        XCTAssertFalse(spans(source, .c, line: 4).contains { $0.kind == .comment })
    }

    func testAnEditPropagatesCarryStateOnlyAsFarAsItHasTo() {
        let doc = Document()
        _ = doc.insert(Array("one\ntwo\nthree\n".utf8))
        doc.highlighter.reset(language: .c, buffer: doc.buffer)
        _ = doc.highlighter.tokens(line: 2, buffer: doc.buffer)
        // Opening a block comment on line 0 must recolour line 2.
        doc.caret = 0
        _ = doc.insert(Array("/*".utf8))
        XCTAssertTrue(doc.highlighter.tokens(line: 2, buffer: doc.buffer)
            .contains { $0.kind == .comment })
    }

    func testAnUnknownExtensionIsNotHighlighted() {
        XCTAssertEqual(Language.forPath("notes.xyz").name, "text")
        XCTAssertTrue(spans("let n = 42", .plain, line: 0).isEmpty)
    }
}

final class FileIndexTests: XCTestCase {

    func testFuzzyRankingPrefersSegmentStartsAndShorterPaths() {
        let index = FileIndex()
        let dir = NSTemporaryDirectory() + "beam-fileindex-test-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dir + "/docs", withIntermediateDirectories: true)
        for p in ["src/renderer.rs", "src/render_loop.rs", "docs/rendering.md", "unrelated.txt"] {
            fm.createFile(atPath: dir + "/" + p, contents: Data("x".utf8))
        }
        defer { try? fm.removeItem(atPath: dir) }

        index.scan(root: dir)
        XCTAssertEqual(index.paths.count, 4)
        let hits = index.filter("rend", limit: 10).map { index.paths[$0] }
        XCTAssertFalse(hits.contains("unrelated.txt"))
        XCTAssertEqual(hits.first, "src/renderer.rs")
        XCTAssertTrue(index.filter("zzzz", limit: 10).isEmpty)
    }
}
