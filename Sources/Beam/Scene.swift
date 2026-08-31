import Foundation
import BeamCore

/// Writes instances straight into the renderer's staging buffer — no
/// intermediate array, no per-frame allocation. This is the keystroke hot path
/// (PLAN.md §5-L2, malloc budget), so it stays a struct over a raw pointer.
struct InstanceWriter {
    let out: UnsafeMutablePointer<Renderer.Instance>
    let cap: Int
    private(set) var count = 0

    init(_ out: UnsafeMutablePointer<Renderer.Instance>, cap: Int) {
        self.out = out
        self.cap = cap
    }

    mutating func put(col: Int, row: Int, glyph: UInt16, ink: Renderer.Ink, alpha: UInt8 = 255) {
        guard count < cap, col >= 0, row >= 0, alpha > 0 else { return }
        out[count] = Renderer.Instance(col: col, row: row, glyph: glyph, ink: ink, alpha: alpha)
        count += 1
    }

    /// A filled rectangle of cells, drawn from the solid-block glyph.
    ///
    /// **This is the whole GUI vocabulary** (PLAN.md §5.3). Selection, the
    /// caret's row, an overlay's plane, the scrim behind it, a hovered row — a
    /// terminal can only colour a character, and every one of those is instead
    /// a *surface*. On a glyph grid they cost one instance per cell in the same
    /// buffer as the text, so Beam gets the single most GUI-ish affordance
    /// there is for no draw call and no new machinery. Write the fill BEFORE
    /// the text that sits on it: the blend is premultiplied source-over in
    /// instance order, so later instances composite over earlier ones.
    mutating func fill(col: Int, row: Int, cols: Int, rows: Int,
                       ink: Renderer.Ink, alpha: UInt8 = 255) {
        guard cols > 0, rows > 0, alpha > 0 else { return }
        for r in row..<(row + rows) {
            for c in col..<(col + cols) {
                put(col: c, row: r, glyph: GlyphAtlas.blockGlyphIndex, ink: ink, alpha: alpha)
            }
        }
    }

    /// Draws a string, **one cell per Unicode scalar**.
    ///
    /// It used to iterate UTF-8 *bytes* and advance the column for each one,
    /// which silently mangled every non-ASCII character: a two-byte `é` drew
    /// nothing and consumed two cells, so the rest of the line slid left by one
    /// and stayed wrong. That was survivable while Beam's only text was its own
    /// ASCII chrome; it is a corruption bug the moment a real file is opened
    /// (PLAN.md §5.3). Scalars outside the atlas resolve through the glyph
    /// cache, which rasterizes on demand; anything it cannot supply draws the
    /// replacement glyph rather than a hole, because a missing character that
    /// is *visibly* missing is honest and a missing character that shifts the
    /// line is not.
    @discardableResult
    mutating func text(_ s: String, col: Int, row: Int, ink: Renderer.Ink, alpha: UInt8 = 255) -> Int {
        var c = col
        for scalar in s.unicodeScalars {
            put(col: c, row: row, glyph: GlyphCache.shared.glyph(for: scalar), ink: ink, alpha: alpha)
            c += 1
        }
        return c
    }
}

/// Every pixel Beam draws. Two surfaces, one overlay, one atlas, two draw calls.
///
/// **The layout grid** (PLAN.md §5.2 composition, §5.3 the editor). Beam has
/// one alignment grid and everything obeys it, so the app reads as one designed
/// page rather than as screens that happen to share a font:
///
/// ```
///   col:  0   4  6                                              cols-1
///         |   |  |                                                   |
///  row 0  |      (traffic lights live in this band — nothing is drawn here)
///  row 1  |      renderer.rs ·          <- the name, where a title would be
///  row 3  |   1  use std::sync::Arc;                                 #
///  row 4  |   2                                                      #
///  row 5  |   3  pub struct Renderer {                               #  <- scroll
///   ...   |      ^gutter hangs LEFT of the text margin
///  last   |      12:25                    ▪▪ 2 nearby ⌘K   p50 4.2 ms
/// ```
///
/// Two spacing rules do most of the work. **List items get air** — an overlay's
/// rows and a peer list read as lists rather than as code listings. **Paragraph
/// lines do not** — the two lines of a designed empty state are one sentence
/// and stay adjacent. And the page is anchored at both ends: the document's
/// name at the top, one quiet instrument line along the bottom.
enum Scene {
    /// Left inset, in cells. 6 cells lands just past the right edge of the
    /// traffic lights — so the chrome sits in the margin the design already
    /// reserved instead of on top of anything.
    static let margin = 6
    /// First row anything is drawn on. Rows 0–2 are the band the traffic lights
    /// occupy; leaving them clear is what makes a title-less window look
    /// deliberate rather than broken.
    static let topRow = 3
    /// On the join-code surface, the row carrying who you are joining — three
    /// rows under the mark, the same rhythm every other block uses.
    static let identityRow = topRow + 3

    // MARK: - The join code

    /// 3x5 block digits, drawn from the solid-block glyph. Cells are 1:2, so a
    /// square "pixel" is `2s` cells wide by `s` rows tall — which means the code
    /// can only be scaled in whole steps, and it is scaled as far as the window
    /// allows. This screen is the one users hold up to each other across a
    /// desk; a code nobody bothers to compare authenticates nothing, so it is
    /// set as the largest thing in the product by a wide margin.
    private static let digitRows: [[UInt8]] = [
        [0b111, 0b101, 0b101, 0b101, 0b111],  // 0
        [0b010, 0b110, 0b010, 0b010, 0b111],  // 1
        [0b111, 0b001, 0b111, 0b100, 0b111],  // 2
        [0b111, 0b001, 0b111, 0b001, 0b111],  // 3
        [0b101, 0b101, 0b111, 0b001, 0b001],  // 4
        [0b111, 0b100, 0b111, 0b001, 0b111],  // 5
        [0b111, 0b100, 0b111, 0b101, 0b111],  // 6
        [0b111, 0b001, 0b001, 0b001, 0b001],  // 7
        [0b111, 0b101, 0b111, 0b101, 0b111],  // 8
        [0b111, 0b101, 0b111, 0b001, 0b111],  // 9
    ]
    static let digitHeight = 5

    /// Geometry of the six-digit code at a given whole-number scale.
    struct CodeMetrics {
        let scale: Int
        /// One block "pixel", in cells and rows — square by construction.
        var pixelCols: Int { 2 * scale }
        var pixelRows: Int { scale }
        var digitCols: Int { 3 * pixelCols }
        var digitRows: Int { digitHeight * pixelRows }
        /// Between digits inside a group.
        var gap: Int { max(1, scale) }
        /// Between the two groups of three. Humans compare 3+3 far more
        /// reliably than a run of six, and the whole security model is a human
        /// comparing them — so the grouping is a correctness feature, not styling.
        var groupGap: Int { 3 * scale }
        var totalCols: Int { 6 * digitCols + 4 * gap + groupGap }

        /// Left edge of digit `i`, relative to the block's own left edge.
        func offset(of i: Int) -> Int {
            i * (digitCols + gap) + (i >= 3 ? groupGap - gap : 0)
        }

        /// The largest scale whose block fits the available width.
        static func fitting(cols: Int) -> CodeMetrics {
            let available = cols - 2 * margin
            for scale in stride(from: 3, through: 1, by: -1) {
                let m = CodeMetrics(scale: scale)
                if m.totalCols <= available { return m }
            }
            return CodeMetrics(scale: 1)
        }
    }

    static func digit(_ d: Int, into w: inout InstanceWriter, col: Int, row: Int,
                      metrics: CodeMetrics, ink: Renderer.Ink, alpha: UInt8) {
        guard d >= 0, d < 10 else { return }
        let bits = digitRows[d]
        for r in 0..<digitHeight {
            for c in 0..<3 where bits[r] & (0b100 >> c) != 0 {
                for dy in 0..<metrics.pixelRows {
                    for dx in 0..<metrics.pixelCols {
                        w.put(col: col + c * metrics.pixelCols + dx,
                              row: row + r * metrics.pixelRows + dy,
                              glyph: GlyphAtlas.blockGlyphIndex, ink: ink, alpha: alpha)
                    }
                }
            }
        }
    }

    /// Six digits, both screens, one keypress each. The gesture already landed
    /// — this surface is drawn before any network byte moves, which is why the
    /// connection feels instant and why the dashes become digits rather than
    /// the screen appearing only once the handshake lands.
    static func pairing(_ app: AppModel, sas: String, into w: inout InstanceWriter, now: Double,
                        cols: Int, rows: Int) {
        w.text("beam", col: margin, row: topRow, ink: .accent)
        let ink = Renderer.Ink.peer(app.joiningInk)
        w.put(col: margin, row: identityRow, glyph: GlyphAtlas.chipGlyphIndex, ink: ink)
        w.text(app.joiningName, col: margin + 3, row: identityRow, ink: .dim)

        let m = CodeMetrics.fitting(cols: cols)
        let codeCol = max(margin, (cols - m.totalCols) / 2)
        // The code and its two caption lines are centred as one block, so the
        // digits sit on the optical centre of the window rather than the
        // arithmetic one — the caption's weight is part of the composition.
        let captionGap = 3
        let blockRows = m.digitRows + captionGap + 2
        let codeRow = max(identityRow + 3, (rows - blockRows) / 2)

        let digits = Array(sas.utf8)
        for i in 0..<6 {
            let col = codeCol + m.offset(of: i)
            if digits.count == 6, digits[i] >= 48, digits[i] <= 57 {
                digit(Int(digits[i] - 48), into: &w, col: col, row: codeRow,
                      metrics: m, ink: .accent, alpha: 255)
            } else {
                // Waiting on the handshake: a rule where each digit will land,
                // on the digit block's own centre line so the code resolves in
                // place instead of jumping when it arrives.
                for c in 0..<m.digitCols {
                    w.put(col: col + c, row: codeRow + m.digitRows / 2,
                          glyph: GlyphAtlas.ruleGlyphIndex, ink: .faint)
                }
            }
        }

        let footRow = codeRow + m.digitRows + captionGap
        if sas.isEmpty {
            w.text("connecting...", col: codeCol, row: footRow, ink: .faint)
        } else {
            w.text("same code on both screens?", col: codeCol, row: footRow, ink: .dim)
            let action = app.isHost ? "return to connect" : "waiting for \(app.joiningName)"
            w.text("\(action)   esc to cancel", col: codeCol, row: footRow + 1, ink: .faint)
        }
    }

    // MARK: - The editor

    /// **The whole frame, for whichever surface is up, as its planes.**
    ///
    /// `GridView`, `--dump-scene` and `--screenshot` all call this one function,
    /// so the window, the ASCII view and the PNGs cannot describe different
    /// layouts — they describe the same one by construction rather than by
    /// agreement (PLAN.md §5.2). It is also the only place that knows Beam has
    /// two planes.
    static func frame(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                      cols: Int, rows: Int, widthPx: Int, hud: [Span]) -> [Renderer.Plane] {
        switch app.surface {
        case .pairing:
            pairing(app, sas: app.session?.sas ?? app.debugSAS ?? "", into: &w, now: now, cols: cols, rows: rows)
            return [Renderer.Plane(count: w.count)]
        case .editor:
            editorDocument(app, into: &w, now: now, cols: cols, rows: rows)
            let documentCount = w.count
            editorChrome(app, into: &w, now: now, cols: cols, rows: rows, hud: hud)

            let L = EditorLayout(cols: cols, rows: rows, lineCount: app.doc.buffer.lineCount)
            let cellH = max(1, app.cellHeightPx)
            let originY = cellH / 2
            return [
                Renderer.Plane(
                    count: documentCount,
                    // Whole pixels: the sub-cell remainder of the scroll, and
                    // nothing else. This is what makes scrolling continuous
                    // while every glyph still lands on a device pixel.
                    originOffsetPx: SIMD2(0, Float(-(app.doc.scrollPx % cellH))),
                    // A line scrolled halfway out is clipped here rather than
                    // allowed to run under the filename or the status line.
                    scissorPx: (x: 0, y: originY + L.topRow * cellH,
                                width: widthPx, height: L.docRows * cellH)),
                Renderer.Plane(count: w.count - documentCount),
            ]
        }
    }

    /// Where everything on the editor surface goes, derived once per frame.
    ///
    /// Beam has no title bar, so **row 1 is the document's name** — exactly
    /// where a title would be, past the traffic lights, on the same 6-cell
    /// margin every other surface obeys. The document starts at row 3, below
    /// the band the lights occupy. The last row is the status line.
    ///
    /// **Line numbers hang to the LEFT of the text margin.** The code keeps
    /// column 6, so `beam`, the filename and the first character of every line
    /// all sit on one alignment; the gutter lives in the margin the design
    /// already reserved for chrome instead of pushing the text right. Only a
    /// file with more lines than fit in that margin moves the code (PLAN.md §5.3).
    struct EditorLayout {
        let cols: Int, rows: Int
        /// The tab strip sits **beside the traffic lights**, on their own row.
        ///
        /// Measured rather than assumed: on a `fullSizeContentView` window the
        /// lights occupy device pixels x 20...140, y 25...50 — which is grid
        /// row **0**, columns 0...6, and nothing else. So row 0 is not a band
        /// that has to be left empty; it is a row with six columns spoken for.
        /// Tabs start at column 8 and share it, the way every modern Mac app
        /// puts its tabs level with the lights.
        let tabRow = 0
        /// First document row — the one immediately below the lights. §5.3
        /// spent five rows on non-document chrome (blank, filename, blank, a
        /// blank above the status line, and the status line); this spends two,
        /// the tab row and the status line. **Three more editing rows than
        /// §5.3, with tabs, a rail and a full menu bar added.**
        let topRow = 1
        let statusRow: Int
        let docRows: Int
        /// The left icon rail, in cells. Vertical chrome costs zero editing
        /// rows, which is the entire reason the rail is where the navigation
        /// lives (PLAN.md §5.4).
        let railCols = 4
        /// Column the last digit of a line number sits on.
        let gutterRight: Int
        let codeCol: Int
        let textCols: Int
        /// Where the tab strip starts. Fixed, not derived from the line count:
        /// tabs that slid sideways when you switched to a longer file would be
        /// the worst kind of motion.
        var tabCol: Int { railCols + 4 }
        /// First row a rail icon may occupy. One row below the document's
        /// first line, so the rail does not start hard against the tab strip's
        /// divider.
        var railTopRow: Int { topRow + 1 }

        init(cols: Int, rows: Int, lineCount: Int) {
            self.cols = cols
            self.rows = rows
            statusRow = max(1, rows - 1)
            docRows = max(1, statusRow - topRow)
            var digits = 1
            var n = max(1, lineCount)
            while n >= 10 { n /= 10; digits += 1 }
            // The gutter hangs between the rail and the code, and the code
            // column only moves for a file with more lines than fit there.
            let code = max(railCols + 4, digits + railCols + 2)
            codeCol = code
            gutterRight = code - 2
            textCols = max(1, cols - code - 1)
        }

        func row(ofLine line: Int, topLine: Int) -> Int { topRow + (line - topLine) }
    }

    // MARK: - Tabs and the rail

    /// Walks the tab strip, handing each tab its index, start column and width.
    /// Drawing and hit-testing both go through it, so a tab can never be drawn
    /// somewhere you cannot click it. Non-escaping, so it allocates nothing on
    /// the render path.
    static func forEachTab(_ app: AppModel, _ layout: EditorLayout,
                           _ body: (_ index: Int, _ startCol: Int, _ width: Int) -> Void) {
        var col = layout.tabCol
        for i in app.documents.indices {
            // Two cells of padding, the name, a space, and the mark. Tabs abut:
            // a hairline separates them, which is what a modern tab strip does
            // and what makes the active tab read as a raised surface rather
            // than as a floating pill.
            let width = app.tabTitle(i).unicodeScalars.count + 6
            guard col + width <= layout.cols - 1 else { return }
            body(i, col, width)
            col += width
        }
    }

    /// One rail item: an icon and the command it runs.
    struct RailItem {
        let icon: UInt16
        let commandID: String
        /// Which overlay being open means this item is the active one.
        let overlay: AppModel.Overlay
    }

    /// The rail, top to bottom. Change 2 adds `changes` and `history` here and
    /// nowhere else.
    static let railItems: [RailItem] = [
        RailItem(icon: GlyphAtlas.filesIconIndex, commandID: "file.open", overlay: .files),
        RailItem(icon: GlyphAtlas.peersIconIndex, commandID: "session.peers", overlay: .peers),
    ]
    /// Rail rows are three apart. Two was the same rhythm the peer list uses,
    /// and it was wrong here: a peer row is text and reads as a line in a list,
    /// while an icon is a *target* and needs the air a target needs. Three rows
    /// costs nothing — the rail is beside the text, not above it.
    static let railRowStride = 3
    static func railRow(_ i: Int, _ layout: EditorLayout) -> Int {
        layout.railTopRow + i * railRowStride
    }
    static func railIndex(atRow row: Int, _ layout: EditorLayout) -> Int {
        (row - layout.railTopRow) / railRowStride
    }

    /// The **document plane**: gutter, fills, code, carets. Its origin carries
    /// the sub-cell scroll offset and it is clipped to the text viewport, which
    /// is why it cannot share a draw call with the chrome (PLAN.md §5.3).
    static func editorDocument(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                               cols: Int, rows: Int) {
        let doc = app.doc
        let buffer = doc.buffer
        let L = EditorLayout(cols: cols, rows: rows, lineCount: buffer.lineCount)
        let cellH = app.cellHeightPx
        let topLine = doc.scrollPx / max(1, cellH)
        let firstCol = doc.scrollXPx / max(1, app.cellWidthPx)
        let caretLine = buffer.line(ofOffset: doc.caret)
        let selection = doc.selection
        // One row past the bottom: a pixel-quantized scroll always exposes part
        // of a line the cell grid does not have room for, and the scissor is
        // what makes drawing it safe.
        let lastLine = min(buffer.lineCount - 1, topLine + L.docRows)

        guard topLine <= lastLine else { return }
        for line in topLine...lastLine {
            let r = L.row(ofLine: line, topLine: topLine)
            let range = buffer.lineRange(line)

            // --- Surfaces first: later instances composite over earlier ones.
            if line == caretLine && selection == nil {
                w.fill(col: 0, row: r, cols: cols, rows: 1, ink: .activeLine)
            }
            if let sel = selection, sel.lowerBound <= range.upperBound, sel.upperBound >= range.lowerBound {
                let from = max(sel.lowerBound, range.lowerBound)
                let to = min(sel.upperBound, range.upperBound)
                let c0 = doc.cellColumn(ofOffset: from) - firstCol
                var c1 = doc.cellColumn(ofOffset: to) - firstCol
                // A selection that runs through a line's end shows the newline
                // it swallowed as one extra cell, which is how a reader can
                // tell "to the end of this line" from "to its last character".
                if sel.upperBound > range.upperBound { c1 += 1 }
                if c1 > c0 {
                    w.fill(col: L.codeCol + max(0, c0), row: r,
                           cols: min(c1, L.textCols) - max(0, c0), rows: 1, ink: .selection)
                }
            }

            // --- The line number, in the margin, brighter on the caret's line.
            let label = "\(line + 1)"
            w.text(label, col: L.gutterRight - label.count + 1, row: r,
                   ink: line == caretLine ? .dim : .faint)

            // --- The text.
            drawLine(doc, line: line, range: range, into: &w,
                     col: L.codeCol, row: r, firstCol: firstCol, maxCols: L.textCols)

            // --- Carets, over everything on the row.
            //
            // A thin bar, not a block. The block was the terminal talking: it
            // covers the character you are about to type over, it reads as a
            // selection, and it is the single strongest "this is a TUI" signal
            // left in the product. It is drawn even when there IS a selection,
            // at the selection's active end, because that is where the next
            // keystroke goes. Its blink is a shader function of one uniform —
            // nothing here knows the phase (PLAN.md §5.5).
            if line == caretLine {
                let c = doc.cellColumn(ofOffset: doc.caret) - firstCol
                if c >= 0 && c <= L.textCols {
                    w.put(col: L.codeCol + c, row: r, glyph: GlyphAtlas.caretGlyphIndex, ink: .caret)
                }
            }
            if let remote = app.remote, app.remoteIsInFrontDocument, remote.line == line {
                let c = remote.cellColumn - firstCol
                if c >= 0 && c <= L.textCols {
                    let ink = Renderer.Ink.peer(remote.inkIndex)
                    w.put(col: L.codeCol + c, row: r, glyph: GlyphAtlas.barGlyphIndex, ink: ink)
                    // Their name trails the caret, on the same row, and only
                    // where the row is actually empty — floating it above put a
                    // permanent label on top of the line above, which on a flat
                    // grid is just unreadable code (PLAN.md §5.1).
                    let labelCol = c + 2
                    if range.upperBound <= doc.offset(line: line, cellColumn: labelCol),
                       labelCol + remote.name.count <= L.textCols {
                        w.text(remote.name, col: L.codeCol + labelCol, row: r, ink: ink,
                               alpha: AppModel.alpha(since: remote.since, now: now))
                    }
                }
            }
        }
    }

    /// One line of the document, decoded from UTF-8, tabs expanded, coloured by
    /// the highlighter's cached spans.
    ///
    /// The ASCII test is inline and does not go through `GlyphCache`: a full
    /// screen is ~3500 characters and a dictionary lookup on each would cost
    /// more than Beam's entire measured commit path (PLAN.md §5.3).
    private static func drawLine(_ doc: Document, line: Int, range: Range<Int>,
                                 into w: inout InstanceWriter,
                                 col: Int, row: Int, firstCol: Int, maxCols: Int) {
        let spans = doc.highlighter.tokens(line: line, buffer: doc.buffer)
        var spanIndex = 0
        var cell = 0
        var i = range.lowerBound
        // UTF-8 continuation bytes are consumed by the scalar they belong to;
        // an incomplete sequence draws the replacement box rather than shifting
        // the rest of the line (PLAN.md §5.3).
        doc.buffer.withRaw { base, gapStart, gapLen in
            @inline(__always) func at(_ k: Int) -> UInt8 { base[k < gapStart ? k : k + gapLen] }
            while i < range.upperBound {
                let b = at(i)
                if b == 0x09 {
                    cell += Document.tabWidth - (cell % Document.tabWidth)
                    i += 1
                    continue
                }
                let rel = Int32(i - range.lowerBound)
                while spanIndex < spans.count && spans[spanIndex].end <= rel { spanIndex += 1 }
                var ink = Renderer.Ink.fg
                if spanIndex < spans.count, spans[spanIndex].start <= rel {
                    ink = Renderer.ink(for: spans[spanIndex].kind)
                }

                var glyph: UInt16
                var width = 1
                if b >= 32 && b < 127 {
                    glyph = UInt16(b - 32)
                } else if b < 0x80 {
                    glyph = GlyphAtlas.replacementGlyphIndex
                } else {
                    // Decode the scalar so a multi-byte character occupies
                    // exactly one cell — the bug that made every column after
                    // an accented letter wrong.
                    var len = 1
                    if b & 0xE0 == 0xC0 { len = 2 } else if b & 0xF0 == 0xE0 { len = 3 }
                    else if b & 0xF8 == 0xF0 { len = 4 }
                    var value: UInt32 = UInt32(b & (len == 2 ? 0x1F : len == 3 ? 0x0F : len == 4 ? 0x07 : 0x7F))
                    var ok = i + len <= range.upperBound
                    if ok {
                        for k in 1..<len {
                            let c = at(i + k)
                            if c & 0xC0 != 0x80 { ok = false; break }
                            value = (value << 6) | UInt32(c & 0x3F)
                        }
                    }
                    glyph = ok ? (UnicodeScalar(value).map { GlyphCache.shared.glyph(forNonASCII: $0) }
                                  ?? GlyphAtlas.replacementGlyphIndex)
                               : GlyphAtlas.replacementGlyphIndex
                    width = len
                }
                let c = cell - firstCol
                if c >= 0 {
                    if c >= maxCols { return }
                    w.put(col: col + c, row: row, glyph: glyph, ink: ink)
                }
                cell += 1
                i += width
            }
        }
    }

    /// The **chrome plane**: the filename, the status line, the scroll
    /// indicator, and any overlay. It sits on the whole-pixel grid and does not
    /// move when the document scrolls.
    static func editorChrome(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                             cols: Int, rows: Int, hud: [Span]) {
        let doc = app.doc
        let L = EditorLayout(cols: cols, rows: rows, lineCount: doc.buffer.lineCount)

        // Row 0: the tab strip, level with the traffic lights.
        //
        // A hairline runs the full width under it, **broken beneath the active
        // tab** — the oldest trick in tab design and still the clearest: the
        // front document is not a highlighted row in a list, it is the top of
        // the surface you are looking at, and the gap in the line is what says
        // so. Everything here is one device pixel or one filled cell; there is
        // no border machinery, because on a glyph grid there does not need to
        // be.
        var activeTabSpan: Range<Int>?
        forEachTab(app, L) { i, col, width in
            let d = app.documents[i]
            let active = i == app.activeIndex
            if active {
                activeTabSpan = col..<(col + width)
                w.fill(col: col, row: L.tabRow, cols: width, rows: 1, ink: .surface)
            } else if i > 0 {
                // A seam between adjacent inactive tabs, never against the
                // active one — its own fill already separates it.
                w.put(col: col, row: L.tabRow, glyph: GlyphAtlas.dividerVIndex, ink: .edge)
            }
            var c = w.text(app.tabTitle(i), col: col + 2, row: L.tabRow, ink: active ? .fg : .faint)
            c += 1
            if d.isModified {
                w.put(col: c, row: L.tabRow, glyph: GlyphAtlas.dotGlyphIndex,
                      ink: active ? .dim : .faint)
            } else if active {
                w.put(col: c, row: L.tabRow, glyph: GlyphCache.shared.glyph(for: "\u{00D7}"),
                      ink: .faint)
            }
        }
        for c in 0..<cols where !(activeTabSpan?.contains(c) ?? false) {
            w.put(col: c, row: L.tabRow, glyph: GlyphAtlas.dividerHIndex, ink: .edge)
        }

        // The rail: vertical chrome, which costs no editing rows at all.
        for (i, item) in railItems.enumerated() {
            let r = railRow(i, L)
            guard r < L.statusRow else { break }
            let active = app.overlay == item.overlay
            // The rail is primary navigation, so its resting state is `dim`,
            // not `faint`: an icon nobody can see is a keyboard shortcut with
            // extra steps. And when someone is nearby, the peers icon takes a
            // PEER colour rather than getting brighter — the rail then carries
            // presence in the same language the status line and the overlay use,
            // instead of inventing a second one (PLAN.md §5.2, the identity set).
            var ink: Renderer.Ink = active ? .fg : .dim
            if item.overlay == .peers, !active, let first = app.peers.first {
                ink = .peer(first.inkIndex)
            }
            if active { w.fill(col: 0, row: r, cols: L.railCols, rows: 1, ink: .surface) }
            // An icon is two cells wide, centred in the rail.
            let c = (L.railCols - 2) / 2
            w.put(col: c, row: r, glyph: item.icon, ink: ink)
            w.put(col: c + 1, row: r, glyph: item.icon + 1, ink: ink)
        }

        // A seam down the rail's right edge and another above the status line.
        // Both are one device pixel and both sit on a cell edge, so they cost
        // no row and no column — the difference between "a grid of characters"
        // and "a window with regions in it" is a few hundred single pixels.
        for r in L.topRow..<L.statusRow {
            w.put(col: L.railCols, row: r, glyph: GlyphAtlas.dividerVIndex, ink: .edge)
        }
        for c in 0..<cols {
            w.put(col: c, row: L.statusRow - 1, glyph: GlyphAtlas.dividerHIndex, ink: .edge)
        }

        if let err = doc.ioError {
            w.text(err, col: L.codeCol, row: L.statusRow, ink: .red)
        }

        // The scroll indicator: drawn, never animated. An animated scrollbar
        // pins the display link awake, and nothing in Beam does that.
        let cellH = max(1, app.cellHeightPx)
        let total = doc.buffer.lineCount
        if total > L.docRows {
            let topLine = doc.scrollPx / cellH
            let height = max(2, L.docRows * L.docRows / total)
            let span = max(1, total - L.docRows)
            let offset = min(L.docRows - height, (L.docRows - height) * topLine / span)
            w.fill(col: cols - 1, row: L.topRow + max(0, offset), cols: 1, rows: height, ink: .edge)
        }

        // The status line: where you are on the left, who is here and how fast
        // we are on the right.
        if doc.ioError == nil {
            let pos = doc.buffer.position(ofOffset: doc.caret)
            let c = w.text("\(pos.line + 1):\(doc.cellColumn(ofOffset: doc.caret) + 1)",
                           col: L.codeCol, row: L.statusRow, ink: .faint)
            if let sel = doc.selection {
                w.text("  \(sel.count) selected", col: c, row: L.statusRow, ink: .faint)
            }
        }
        hudLine(into: &w, spans: presenceSpans(app, now: now) + hud, cols: cols, rows: rows)

        if let overlay = app.overlay {
            self.overlay(app, overlay, into: &w, now: now, cols: cols, rows: rows)
        }
    }

    /// Presence, on the left of the status line's right-hand run.
    ///
    /// This is where "the launch screen IS the peer list" went (PLAN.md §5.3).
    /// A peer arriving is still visible within a second — and now it is visible
    /// *while you are working*, which a launch screen never was. A permission
    /// problem says so here in red rather than hiding behind a keypress: §2
    /// forbids a denial that reads as an empty network, and that is a
    /// correctness rule, not a courtesy.
    static func presenceSpans(_ app: AppModel, now: Double) -> [Span] {
        if app.remote != nil { return [] }   // in a session: the peer's own chip and RTT say it
        switch app.presence {
        case .localNetworkDenied:
            return [Span("local network is off", .red), Span("  ⌘K   ", .faint)]
        case .advertiseFailed:
            return [Span("they cannot see you", .red), Span("  ⌘K   ", .faint)]
        case .searching, .ok:
            break
        }
        guard !app.peers.isEmpty else { return [] }
        var spans: [Span] = []
        for peer in app.peers.prefix(6) {
            spans.append(Span(glyph: GlyphAtlas.chipGlyphIndex, .peer(peer.inkIndex),
                              alpha: AppModel.alpha(since: peer.appearedAt, now: now)))
        }
        spans.append(Span("  \(app.peers.count) nearby", .dim))
        spans.append(Span("  ⌘K   ", .faint))
        return spans
    }

    // MARK: - The overlay

    /// One mechanism, two lists (PLAN.md §5.3). A scrim over the document, a
    /// panel above it, a query row, a rule, and rows with selection and hover
    /// fills. It is a *layer*, not a surface: you are choosing something to do
    /// **to** the document, and losing sight of it would be a worse answer than
    /// dimming it.
    /// Wide enough for the longest designed line in it — the Settings path a
    /// Local Network denial names, which is the one string in Beam that cannot
    /// be shortened without making it less useful. `--dump-scene` caught it
    /// running off a 56-cell panel onto the scrim, which is the whole argument
    /// for a structural view that is diffable.
    static let overlayWidth = 64
    static let overlayTopRow = 4
    static let overlayMaxRows = 10

    /// Grid row of result `i`, shared with the click hit-test.
    static func overlayRow(_ i: Int) -> Int { overlayTopRow + 3 + i }
    static func overlayIndex(atRow row: Int) -> Int { row - (overlayTopRow + 3) }
    static func overlayCol(cols: Int) -> Int { max(0, (cols - overlayWidth) / 2) }

    static func overlay(_ app: AppModel, _ kind: AppModel.Overlay,
                        into w: inout InstanceWriter, now: Double, cols: Int, rows: Int) {
        // The scrim is written at 225/255 rather than something gentler because
        // the blend is in LINEAR light (§5.2): three quarters of coverage there
        // is only about half the perceived brightness, so a scrim tuned by the
        // sRGB number would barely dim anything.
        w.fill(col: 0, row: 0, cols: cols, rows: rows, ink: .scrim, alpha: 225)

        let items = app.overlayItems
        let shown = min(items.count, overlayMaxRows)
        let pcol = overlayCol(cols: cols)
        let panelRows = 3 + max(app.overlayEmptyLines.count, shown) + 1
        w.fill(col: pcol, row: overlayTopRow, cols: overlayWidth, rows: panelRows, ink: .surface)

        let label: String
        switch kind {
        case .files: label = "open"
        case .peers: label = "who's nearby"
        case .commands: label = "run"
        }
        var c = w.text(label, col: pcol + 2, row: overlayTopRow + 1, ink: .faint) + 1
        c = w.text(app.overlayQuery, col: c, row: overlayTopRow + 1, ink: .fg)
        w.put(col: c, row: overlayTopRow + 1, glyph: GlyphAtlas.caretGlyphIndex, ink: .caret)
        for i in 0..<overlayWidth {
            w.put(col: pcol + i, row: overlayTopRow + 2, glyph: GlyphAtlas.ruleGlyphIndex, ink: .edge)
        }

        if items.isEmpty {
            // Paragraph lines do not get air between them: the two lines of a
            // designed empty state are one sentence (PLAN.md §5.2).
            for (i, line) in app.overlayEmptyLines.enumerated() {
                w.text(line.0, col: pcol + 2, row: overlayRow(i), ink: line.1)
            }
            return
        }
        for i in 0..<shown {
            let r = overlayRow(i)
            if i == app.overlaySelection {
                w.fill(col: pcol, row: r, cols: overlayWidth, rows: 1, ink: .selection)
            } else if i == app.overlayHover {
                w.fill(col: pcol, row: r, cols: overlayWidth, rows: 1, ink: .hover)
            }
            var c = pcol + 2
            let item = items[i]
            if let n = item.number { c = w.text("\(n)", col: c, row: r, ink: .faint) + 1 }
            if let ink = item.ink {
                w.put(col: c, row: r, glyph: GlyphAtlas.chipGlyphIndex, ink: ink)
                c += 2
            }
            // A shortcut sits right-aligned, the way a menu sets one — the
            // palette and the menu bar are the same table, so they read the same.
            var room = overlayWidth - (c - pcol) - 2
            if let sc = item.shortcut, !sc.isEmpty {
                let n = sc.unicodeScalars.count
                w.text(sc, col: pcol + overlayWidth - 2 - n, row: r, ink: .faint)
                room -= n + 2
            }
            w.text(String(item.title.suffix(max(1, room))), col: c, row: r,
                   ink: i == app.overlaySelection ? .fg : .dim)
        }
    }

    // MARK: - The HUD

    /// One run of the HUD line. The HUD is the only ornament Beam has, and the
    /// numbers in it are the product — so it is set like a caption on an
    /// instrument: labels recede, values are bright, and the unit is quiet
    /// again. One colour for the whole line would make it look like debug
    /// output, which is exactly what it must not look like.
    struct Span {
        let text: String
        let ink: Renderer.Ink
        /// A single mark from the atlas instead of text — the peer chip. The
        /// line is drawn from the same atlas as everything else, so a peer's
        /// colour can appear inline without a character to stand in for it.
        let glyph: UInt16?
        /// So a peer arriving in the presence line fades in on the same
        /// machinery, and under the same fade floor, as everything else.
        let alpha: UInt8

        var width: Int { glyph != nil ? 1 : text.unicodeScalars.count }

        init(_ text: String, _ ink: Renderer.Ink, alpha: UInt8 = 255) {
            self.text = text
            self.ink = ink
            self.glyph = nil
            self.alpha = alpha
        }
        init(glyph: UInt16, _ ink: Renderer.Ink, alpha: UInt8 = 255) {
            self.text = ""
            self.ink = ink
            self.glyph = glyph
            self.alpha = alpha
        }
    }

    /// The status line's right-hand run, inset by the same margin as the left
    /// edge: who is nearby, then live latency against the same budgets.json CI
    /// reads, plus each peer's live RTT. We publish our latency because we are
    /// the only editor that can afford to.
    static func hudLine(into w: inout InstanceWriter, spans: [Span], cols: Int, rows: Int) {
        var width = 0
        for s in spans { width += s.width }
        guard width > 0 else { return }
        var col = max(0, cols - margin - width)
        let row = max(0, rows - 1)
        for s in spans {
            if let g = s.glyph {
                w.put(col: col, row: row, glyph: g, ink: s.ink, alpha: s.alpha)
                col += 1
            } else {
                col = w.text(s.text, col: col, row: row, ink: s.ink, alpha: s.alpha)
            }
        }
    }
}
