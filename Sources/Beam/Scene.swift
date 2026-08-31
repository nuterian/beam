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

    /// **How far the chrome sits below the document's ground.**
    ///
    /// The one tonal decision the whole shell hangs off. Beam's ground is the
    /// darkest thing in the old design, so every piece of chrome had to be
    /// *lighter* than the document to be seen at all — which is backwards, and
    /// it is why the old tab strip read as a highlighted row in a list rather
    /// than as the top edge of the page. Modern editors invert it: the frame
    /// recedes and the document is the raised, lit surface in the middle of it.
    ///
    /// There is no palette entry darker than the ground except `scrim`, and
    /// that is exactly what it is for — so the recess is `scrim` at partial
    /// coverage rather than a new colour. In LINEAR light (§5.2) half coverage
    /// of a near-black over #0D1117 lands around #080B10: about one 8-bit step
    /// per channel, which is all a tonal separation on a dark ground is allowed
    /// to be before it starts looking like a different application's window.
    /// The dump prints nothing for it, correctly — this is lighting, not
    /// structure.
    static let recess: UInt8 = 132

    /// **Air between the tab strip and the first line of code, in device
    /// pixels — and it costs no editing row** (PLAN.md §5.7).
    ///
    /// §5.4 won two editing rows by putting the tabs in the traffic-light band,
    /// and the document then began in the row immediately under them with
    /// nothing in between: the top line of the file sat hard against the strip,
    /// which is the single place Beam read as denser than it should while being
    /// *emptier* than VS Code everywhere else. The row that would fix it is the
    /// scarcest thing in the layout, so it does not buy one.
    ///
    /// It does not have to. The **document plane already carries a whole-pixel
    /// origin offset** — that is the machinery pixel-quantized scrolling is
    /// built on (§5.3) — so the document can be inset from its own viewport by
    /// pixels instead of by cells. A third of a cell reads as deliberate air
    /// and takes a third of a line off the bottom-most row, which is the same
    /// partial row any pixel-quantized scroll already shows.
    ///
    /// Integer division, so it is a whole device pixel at every zoom step.
    /// **Anything that maps a point back to a line must apply it too** —
    /// `GridView.offset(atCol:row:)` is the only such place, and a gap applied
    /// on one side of that pair and not the other is an editor whose clicks
    /// land on the wrong line.
    static func docTopGapPx(cellHeightPx: Int) -> Int { cellHeightPx / 3 }
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
        let m = CodeMetrics.fitting(cols: cols)
        let codeCol = max(margin, (cols - m.totalCols) / 2)
        // **One left edge.** The mark, the identity row, the digits and both
        // caption lines all hang off the digit block's own left edge. They used
        // to split into two columns 72 px apart — the header on the 6-cell
        // margin, the code centred — which on the one screen users hold up to
        // each other read as two unrelated compositions in one window.
        //
        // And the whole stack centres, header included: the code plus its
        // caption used to be centred while five rows of header sat above them,
        // so the composition was top-heavy and left the bottom third of the
        // window empty.
        let captionGap = 3
        // Six: the mark, two rows of air, the identity, then two more before the
        // digits. Four put the identity row hard against the top edge of a
        // ten-row-tall block of solid colour, which is not a gap, it is a
        // collision.
        let headRows = 6
        let blockRows = headRows + m.digitRows + captionGap + 2
        let top = max(topRow, (rows - blockRows) / 2)
        w.text("beam", col: codeCol, row: top, ink: .accent)
        let ink = Renderer.Ink.peer(app.joiningInk)
        w.put(col: codeCol, row: top + 3, glyph: GlyphAtlas.chipGlyphIndex, ink: ink)
        w.text(app.joiningName, col: codeCol + 2, row: top + 3, ink: .dim)
        let codeRow = top + headRows

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
            // Published by GridView from the same metrics the renderer uses, so
            // the scissor and the grid cannot disagree about where row 0 starts.
            let originY = app.originYPx
            return [
                Renderer.Plane(
                    count: documentCount,
                    // Whole pixels, and now two of them: the sub-cell remainder
                    // of the scroll — which is what makes scrolling continuous
                    // while every glyph still lands on a device pixel — and the
                    // designed inset below the tab strip (`docTopGapPx`).
                    originOffsetPx: SIMD2(0, Float(docTopGapPx(cellHeightPx: cellH)
                                                   - (app.doc.scrollPx % cellH))),
                    // A line scrolled halfway out is clipped here rather than
                    // allowed to run under the tab strip or the status line.
                    // The viewport itself does not move with the inset: the gap
                    // is the document sitting lower *inside* it, so the bottom
                    // row gives up the same third of a cell the top gained.
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
        ///
        /// **Six cells, from four** (§5.7). At four it was a 72 px column — 36
        /// pt against VS Code's 48 pt activity bar — carrying an 18 pt icon,
        /// and it read as a margin somebody had put two smudges in. Six cells
        /// is 108 px / 54 pt, and it holds §5.7's 72 px icon with exactly one
        /// cell of air on each side. Horizontal is the axis Beam has to spare
        /// (§5.4); vertical is the one it does not, and this costs none of it.
        let railCols = 6
        /// Width of the line-number field, in cells: **as many digits as this
        /// document actually has**, never fewer than two.
        ///
        /// It was briefly pinned at five — enough for any file under 100,000
        /// lines — so that `codeCol` would be constant and the tab strip could
        /// be nailed to it. That bought one alignment and paid three columns of
        /// permanent indent for it on every ordinary file, which is the wrong
        /// way round: the gutter is on screen always and the alignment is
        /// noticed once.
        ///
        /// Sized to the **document** rather than to the visible rows on
        /// purpose. Viewport-sizing is tighter still, but the width would then
        /// change as you scroll past line 99 or line 999 — and the whole code
        /// column would slide sideways underneath you mid-scroll, which is a
        /// far worse thing to feel than three unused columns are to look at.
        static let minGutterCols = 2
        /// Column the last digit of a line number sits on.
        let gutterRight: Int
        let codeCol: Int
        let textCols: Int
        /// Where the tab strip starts. **Fixed**, and not derived from the
        /// gutter.
        ///
        /// Two constraints fight here and only one can win. The tab strip must
        /// clear the traffic lights, which occupy row 0 out to column 6, so it
        /// cannot start before column 8. And the gutter must be as wide as the
        /// document needs and no wider, so `codeCol` moves from file to file.
        /// They therefore cannot always share an edge.
        ///
        /// The tab wins its own column, because a tab strip that slid sideways
        /// every time you switched documents would be intolerable, while a code
        /// column that sits two cells further right in a 30,000-line file than
        /// in a 30-line one is invisible. §5.3's "one alignment grid" is
        /// amended accordingly: **the tab belongs to the pane, the gutter and
        /// the code belong to the document.** They coincide for any file under
        /// a hundred lines and diverge, quietly, above it.
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
            // As many digits as the document has, and no more. The two cells
            // of air after the field are what separate a line number from the
            // code it indexes.
            let field = max(Self.minGutterCols, digits)
            let code = railCols + field + 2
            codeCol = code
            gutterRight = code - 2
            textCols = max(1, cols - code - 1)
        }

        func row(ofLine line: Int, topLine: Int) -> Int { topRow + (line - topLine) }
    }

    // MARK: - Tabs and the rail

    /// Cells of air on each side of a tab's label. Two cells is 36 device
    /// pixels at 2x — the same optical inset a Mac tab uses, and the reason the
    /// strip reads as a row of surfaces rather than a run of words.
    static let tabPadding = 2
    /// The longest label a tab will set before it truncates. A tab strip whose
    /// tabs resize to their content is a strip whose tabs move under the
    /// pointer, so the cap is on the label and not on the strip.
    static let tabMaxLabel = 20
    /// Room reserved at the right end for the `+N` overflow mark.
    static let tabOverflowCols = 5

    /// A tab's label: the document's name, truncated with an ellipsis rather
    /// than allowed to push its neighbours off the strip. The ellipsis is one
    /// scalar and one cell, so a truncated name costs the same grid as any
    /// other — which is the only reason truncation is cheap enough to be the
    /// default answer here.
    static func tabLabel(_ app: AppModel, _ i: Int) -> String {
        let title = app.tabTitle(i)
        guard title.unicodeScalars.count > tabMaxLabel else { return title }
        return String(String(title.unicodeScalars.prefix(tabMaxLabel - 1))) + "\u{2026}"
    }

    static func tabWidth(_ app: AppModel, _ i: Int) -> Int {
        tabLabel(app, i).unicodeScalars.count + 2 * tabPadding + 2
    }

    /// Column of a tab's close × / unsaved dot. Drawing and hit-testing both
    /// read it here, so the mark can never be somewhere you cannot click it —
    /// which is what truncation would otherwise have quietly broken.
    static func tabMarkCol(_ app: AppModel, _ i: Int, startCol: Int) -> Int {
        startCol + tabPadding + tabLabel(app, i).unicodeScalars.count + 1
    }

    /// Walks the tab strip, handing each tab its index, start column and width,
    /// and returning how many documents did **not** fit. Drawing and
    /// hit-testing both go through it, so a tab can never be drawn somewhere
    /// you cannot click it. Non-escaping, so it allocates nothing on the render
    /// path.
    ///
    /// The two passes exist for the overflow mark: a strip that silently drops
    /// documents off its right edge is the one failure a tab strip is not
    /// allowed to have, so when the tabs do not fit, the last visible one gives
    /// back `tabOverflowCols` and a `+N` takes the space.
    @discardableResult
    static func forEachTab(_ app: AppModel, _ layout: EditorLayout,
                           _ body: (_ index: Int, _ startCol: Int, _ width: Int) -> Void) -> Int {
        var limit = layout.cols - 1
        var col = layout.tabCol
        for i in app.documents.indices {
            let width = tabWidth(app, i)
            if col + width > limit { limit -= tabOverflowCols; break }
            col += width
        }
        col = layout.tabCol
        var drawn = 0
        for i in app.documents.indices {
            let width = tabWidth(app, i)
            guard col + width <= limit else { break }
            body(i, col, width)
            col += width
            drawn += 1
        }
        return app.documents.count - drawn
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
    /// Rail rows, in rows of pitch. The icon is `GlyphAtlas.iconRows` tall, so
    /// this is the icon plus its gap.
    ///
    /// It was 2 when the icon was 1 row — a 72 px pitch around a 36 px mark,
    /// exactly half air, which is the ratio a row of targets wants. §5.7's icon
    /// is 2 rows, so the pitch goes to 3: 108 px around a 72 px mark, which is
    /// the same ratio the rail is now *wide* (72 in 108). The rail is therefore
    /// a column of square targets on a square pitch, which is what an activity
    /// bar is.
    static let railRowStride = GlyphAtlas.iconRows + 1
    /// How strong a hover tile is on chrome that is *recessed* at rest. Full
    /// strength put a hovered background tab above the front one, which inverts
    /// the hierarchy; this lands it just short of the ground. Overlay rows sit
    /// on a lit panel and use the full value.
    static let hoverTileAlpha: UInt8 = 130
    /// Cells the `+` affordance occupies at the end of the strip.
    static let newTabCols = 3
    /// Where `+` starts, given where the tabs ended.
    static func newTabCol(_ app: AppModel, _ layout: EditorLayout) -> Int {
        var end = layout.tabCol
        forEachTab(app, layout) { _, col, width in end = col + width }
        return end
    }
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
            // The lit row starts at the rail's edge, not at the window's. It
            // spans the gutter deliberately — the line number is part of "the
            // line you are on" and every editor worth copying lights it — but
            // running it under the rail made the rail look like a column of the
            // document instead of a region of the window.
            if line == caretLine && selection == nil {
                w.fill(col: L.railCols, row: r, cols: cols - L.railCols, rows: 1, ink: .activeLine)
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
                    cell += doc.tabWidth - (cell % doc.tabWidth)
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

        // --- The frame. The rail and the status row are recessed regions
        // wrapping the document, so the ground between them reads as a lit page
        // sitting *in* the window rather than as the background everything else
        // is painted on. See `recess`.
        //
        // **The status band bleeds two rows past the last one the layout
        // claims**, and the count is not arbitrary. §5.7 stopped splitting the
        // vertical remainder between the two edges and gave all of it to this
        // one, because the top edge belongs to the tab strip; the slack here is
        // therefore `h mod cellH` plus a whole cell, which is strictly less
        // than two cells. Two rows of overhang covers it at any window height
        // and any zoom step, and the GPU clips the rest for free. One row
        // covered the old centred layout and would now leave a lighter strip
        // along the bottom edge — the exact defect this band exists to avoid,
        // just moved.
        w.fill(col: 0, row: L.topRow, cols: L.railCols, rows: L.statusRow - L.topRow,
               ink: .scrim, alpha: recess)
        w.fill(col: 0, row: L.statusRow, cols: cols, rows: 3, ink: .scrim, alpha: recess)

        // Row 0: the tab strip, level with the traffic lights.
        //
        // **The tone is inverted: the front tab is the ground, and the tabs
        // behind it are recessed.** The old design filled the active tab with a
        // colour *lighter* than the document, which is what a selected row in a
        // list looks like; every modern editor does the opposite, because a tab
        // is not an item you picked out of a list — it is the top edge of the
        // page you are reading. Drawn this way the front tab is literally the
        // same pixels as the document below it, and the two read as one
        // continuous surface with a hairline running past on both sides.
        //
        // The recess is laid under the *tabs*, not under the whole row: the
        // grid origin leaves half a cell of ground above row 0, and a band
        // running the full width would put a lighter strip along the top edge
        // of the window. Tabs sit in the middle of the strip, where there is no
        // edge to disagree with.
        var activeTabSpan: Range<Int>?
        forEachTab(app, L) { i, col, width in
            if i == app.activeIndex { activeTabSpan = col..<(col + width) }
        }
        for c in 0..<cols where !(activeTabSpan?.contains(c) ?? false) {
            w.put(col: c, row: L.tabRow, glyph: GlyphAtlas.dividerHIndex, ink: .edge)
        }
        var stripEnd = L.tabCol
        let hiddenTabs = forEachTab(app, L) { i, col, width in
            let d = app.documents[i]
            let active = i == app.activeIndex
            stripEnd = col + width
            if active {
                // The accent bar. It is the one thing that turns "text sitting
                // on the ground" into "the front tab", and it is where the
                // accent belongs: §5.2 reserved it for the mark and the join
                // code, and *where you are* is the same kind of statement.
                // Two device pixels on the cell's top edge — the accent GLYPH,
                // not a filled cell.
                for c in 0..<width {
                    w.put(col: col + c, row: L.tabRow, glyph: GlyphAtlas.tabAccentIndex, ink: .accent)
                }
            }
            if !active {
                w.fill(col: col, row: L.tabRow, cols: width, rows: 1, ink: .scrim, alpha: recess)
                // Hover **lifts the tab out of the recess**, toward the ground
                // the front tab already is. That is the right direction on a
                // strip whose resting state is sunken: the pointer previews
                // what clicking would do. It is drawn in `.hover`, whose alpha
                // the shader multiplies by that slot's animation phase, so the
                // fade costs this code nothing and knows nothing about time
                // (BeamCore.Animator, PLAN.md §5.6).
                if app.hover == .tab(i) {
                    // At partial alpha, so hover lands just SHORT of the ground
                    // the active tab already is. At full strength it overshot
                    // past the front tab, which inverts the hierarchy: the
                    // thing under the pointer must never outrank the thing you
                    // actually have open. Alpha and the animation phase
                    // multiply, so this is one lever, not two.
                    w.fill(col: col, row: L.tabRow, cols: width, rows: 1,
                           ink: .hover, alpha: hoverTileAlpha)
                }
                if i > 0 {
                    // A seam between adjacent recessed tabs, never against the
                    // active one — the tone step already separates that one.
                    w.put(col: col, row: L.tabRow, glyph: GlyphAtlas.dividerVIndex, ink: .edge)
                }
            }
            w.text(tabLabel(app, i), col: col + tabPadding, row: L.tabRow,
                   ink: active ? .fg : .dim)
            if !active, app.hover == .tab(i) {
                // The same label again, brighter, in an animated slot: the
                // phase cross-fades it in over the resting one, so the text
                // *warms up* under the pointer rather than switching.
                w.text(tabLabel(app, i), col: col + tabPadding, row: L.tabRow, ink: .hoverText)
            }
            let mark = tabMarkCol(app, i, startCol: col)
            if d.isModified {
                // `dim` on a background tab too, not `faint`. The dot is the
                // only thing that says a document you cannot see has unsaved
                // work in it — that is information, and information does not
                // get the tertiary step.
                w.put(col: mark, row: L.tabRow, glyph: GlyphAtlas.dotGlyphIndex, ink: .dim)
            } else if active {
                w.put(col: mark, row: L.tabRow, glyph: GlyphCache.shared.glyph(for: "\u{00D7}"),
                      ink: .faint)
            }
        }
        // What ten tabs look like: the strip stops where it runs out, and says
        // how many it is not showing. Silently dropping them is the one thing a
        // tab strip may not do — you would have no way to know a document you
        // opened is still open.
        if hiddenTabs > 0 {
            w.text("+\(hiddenTabs)", col: stripEnd + tabPadding, row: L.tabRow, ink: .faint)
        } else if stripEnd + newTabCols < cols - 1 {
            // A `+` at the end of the strip. There was no way to make a new tab
            // at all with the mouse, and a tab strip without one is the first
            // thing a person reaches for and does not find.
            if app.hover == .newTab {
                w.fill(col: stripEnd, row: L.tabRow, cols: newTabCols, rows: 1,
                       ink: .hover, alpha: hoverTileAlpha)
            }
            w.text("+", col: stripEnd + 1, row: L.tabRow, ink: .dim)
            if app.hover == .newTab {
                w.text("+", col: stripEnd + 1, row: L.tabRow, ink: .hoverText)
            }
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
            // An icon is `iconCols` wide by `iconRows` tall, centred in the
            // rail — and a cell is 1:2, so that block is a SQUARE. The active
            // state is that square filled, which reads as the rounded tile
            // every modern activity bar uses; the old full-width bar was a 2:1
            // slab that said "selected row" in a rail that has no rows.
            let c = (L.railCols - GlyphAtlas.iconCols) / 2
            if active {
                w.fill(col: c, row: r, cols: GlyphAtlas.iconCols, rows: GlyphAtlas.iconRows,
                       ink: .surface)
            } else if app.hover == .rail(i) {
                // Drawn in `.hover`, whose alpha the shader multiplies by that
                // slot's animation phase — the fade costs this code nothing and
                // knows nothing about time (BeamCore.Animator, PLAN.md §5.6).
                w.fill(col: c, row: r, cols: GlyphAtlas.iconCols, rows: GlyphAtlas.iconRows,
                       ink: .hover, alpha: hoverTileAlpha)
            }
            // The icon's cells, left to right and top to bottom. The atlas lays
            // an icon out as a block, so the slot for cell (dx, dy) is the base
            // plus one per column and one atlas ROW per row. Drawn twice under
            // the pointer: the phase cross-fades the bright copy in over the
            // resting one, so the icon *warms up* rather than switching (§5.6).
            let inks: [Renderer.Ink] = (!active && app.hover == .rail(i)) ? [ink, .hoverText] : [ink]
            for pass in inks {
                for dy in 0..<GlyphAtlas.iconRows {
                    for dx in 0..<GlyphAtlas.iconCols {
                        w.put(col: c + dx, row: r + dy,
                              glyph: item.icon + UInt16(dy * GlyphAtlas.atlasCols + dx), ink: pass)
                    }
                }
            }
        }

        // **No hairlines here at all any more.** There used to be two: one down
        // the rail's right edge and one above the status row. Both now repeat a
        // boundary the recess already draws, and the status one was the worse
        // offender — it sat one device pixel above the status band with 9 px of
        // clearance to the cap-tops below it and 36 px of air above, so it read
        // as an underline on the last line of code rather than as the top of a
        // region. A hairline earns its pixel where there is no tone step to do
        // the work; where there is one, it is noise (§5.3).

        // **The empty document says what to do next.** Beam launches into a
        // blank buffer (§5.3), and a blank buffer with no chrome is a window
        // that offers nothing at all — 1150x1850 device pixels of ground and no
        // way in short of knowing the keymap already. Two faint rows under the
        // caret answer that for about forty instances, and they are *not*
        // permanent chrome: the first character you type takes them away, which
        // is the only kind of hint an editor with this brief is allowed.
        if doc.buffer.isEmpty && app.documents.count == 1 && doc.ioError == nil {
            let hintRow = L.topRow + 2
            if hintRow + 2 < L.statusRow {
                w.text("⌘O", col: L.codeCol, row: hintRow, ink: .dim)
                w.text("open a file", col: L.codeCol + 4, row: hintRow, ink: .faint)
                w.text("⌘K", col: L.codeCol, row: hintRow + 1, ink: .dim)
                w.text("who's nearby", col: L.codeCol + 4, row: hintRow + 1, ink: .faint)
            }
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

        // The status line's left-hand run: where you are, and what this file
        // is. See `statusSegments`. It is bounded by where the right-hand run
        // begins, and the right-hand run is never the one that yields.
        let hudSpans = presenceSpans(app, now: now) + hud
        if doc.ioError == nil {
            let limit = hudStartCol(spans: hudSpans, cols: cols) - statusGap
            forEachStatusSegment(app, L, limit: limit) { i, col, seg in
                let n = seg.text.unicodeScalars.count
                if app.hover == .status(i) {
                    // Only a segment that *does* something lights up. A hover
                    // under a readout is a promise the click does not keep —
                    // `hoverTarget` returns nil for those, so this is drawing a
                    // decision that was already made rather than repeating it.
                    w.fill(col: col - 1, row: L.statusRow, cols: n + 2, rows: 1,
                           ink: .hover, alpha: hoverTileAlpha)
                }
                // `dim` for a control, `faint` for a readout — the same step
                // §5.4 used to stop an inactive tab being dimmer than a
                // comment. It is the only thing that says which of these six
                // you can press.
                w.text(seg.text, col: col, row: L.statusRow,
                       ink: seg.action == nil ? .faint : .dim)
                if app.hover == .status(i) {
                    w.text(seg.text, col: col, row: L.statusRow, ink: .hoverText)
                }
            }
        }
        hudLine(into: &w, spans: hudSpans, cols: cols, rows: rows)

        if let overlay = app.overlay {
            self.overlay(app, overlay, into: &w, now: now, cols: cols, rows: rows)
        }
    }

    // MARK: - The status line

    /// **One gap, everywhere.** The status line used to space its two facts at
    /// 1, 2 and 3 cells with no system behind the choice, which §5.2 already
    /// names as the difference between an instrument and debug output. Every
    /// segment is now separated by the same three cells, so the line has a beat
    /// and a new segment cannot invent its own spacing.
    static let statusGap = 3

    /// One segment of the status line's left-hand run.
    struct StatusSegment {
        let text: String
        /// The overlay a click opens, or nil for a readout.
        let action: AppModel.Overlay?
    }

    /// **What Beam knows about the document, said out loud** (PLAN.md §5.7).
    ///
    /// The line carried two facts — the caret's position and a selection count
    /// — while the lexer had already resolved the language, the open path had
    /// the encoding, and `Document` knew its own indentation and line endings.
    /// None of it was hidden on purpose; it was hidden because nothing had ever
    /// asked for it. An editor that knows four things about your file and shows
    /// none of them reads as a prototype next to one that shows all four.
    ///
    /// **Two of them are actionable and two are readouts, and the difference is
    /// visible.** Language and indentation open a picker through the same
    /// overlay mechanism ⌘O and ⌘K already use, so they are set in `dim`; the
    /// encoding and the line ending are facts you cannot currently change, so
    /// they stay `faint` and do not light up under the pointer. Colouring a
    /// readout as if it were a control is how a status bar teaches people to
    /// stop clicking it.
    ///
    /// The right-hand run — presence and the latency readout — is untouched and
    /// stays exactly where it is. It is the brand, and no other editor can
    /// print it.
    static func statusSegments(_ app: AppModel) -> [StatusSegment] {
        let doc = app.doc
        let pos = doc.buffer.position(ofOffset: doc.caret)
        var segs = [StatusSegment(text: "\(pos.line + 1):\(doc.cellColumn(ofOffset: doc.caret) + 1)",
                                  action: nil)]
        if let sel = doc.selection {
            segs.append(StatusSegment(text: "\(sel.count) selected", action: nil))
        }
        // **Ordered by what you would keep if you could only keep one.**
        // `forEachStatusSegment` drops from the right when the window is too
        // narrow, so this order IS the priority order, and it is not VS Code's:
        // there the language sits at the far right, which on a run that
        // truncates from the right would make the most informative fact the
        // first one to disappear. The encoding goes first instead — it is the
        // one segment that can only ever say one thing.
        segs.append(StatusSegment(text: doc.highlighter.language.name, action: .language))
        segs.append(StatusSegment(text: doc.indentsWithTabs ? "tabs \(doc.tabWidth)"
                                                            : "spaces \(doc.tabWidth)",
                                  action: .indent))
        segs.append(StatusSegment(text: doc.lineEnding.rawValue, action: nil))
        segs.append(StatusSegment(text: doc.encoding, action: nil))
        return segs
    }

    /// Walks the left-hand run, handing each segment its index and start
    /// column, and **stopping before it would reach `limit`**.
    ///
    /// Drawing and hit-testing both go through it, so a segment cannot be drawn
    /// somewhere you cannot click it — the rule `forEachTab` exists for, and
    /// the one the tab strip learned the hard way.
    ///
    /// The limit is where the right-hand run begins. The two runs share a row
    /// and the left one grew from two facts to six in §5.7, so on a narrow
    /// window they collide — and when they do it is the *left* run that gives
    /// way, always. The latency readout is the brand and no other editor can
    /// print it; a window narrow enough to lose "UTF-8" is not narrow enough to
    /// lose that. Segments drop from the right, so the caret position — the one
    /// that changes as you work — is the last thing to go.
    static func forEachStatusSegment(_ app: AppModel, _ layout: EditorLayout, limit: Int,
                                     _ body: (_ index: Int, _ startCol: Int,
                                              _ seg: StatusSegment) -> Void) {
        var c = layout.codeCol
        for (i, seg) in statusSegments(app).enumerated() {
            let n = seg.text.unicodeScalars.count
            guard c + n <= limit else { return }
            body(i, c, seg)
            c += n + statusGap
        }
    }

    /// Which segment a column on the status row falls in, or nil for a readout,
    /// a gap, or a segment that did not fit.
    static func statusSegment(atCol col: Int, _ app: AppModel, _ layout: EditorLayout,
                              limit: Int) -> Int? {
        var found: Int?
        forEachStatusSegment(app, layout, limit: limit) { i, start, seg in
            guard found == nil, seg.action != nil else { return }
            // One cell of slop on each side, matching the hover tile's own
            // extent, so the target is exactly the thing that lights up.
            if col >= start - 1, col <= start + seg.text.unicodeScalars.count { found = i }
        }
        return found
    }

    /// Where the right-hand run starts, so the left one knows where to stop.
    static func hudStartCol(spans: [Span], cols: Int) -> Int {
        var width = 0
        for s in spans { width += s.width }
        guard width > 0 else { return cols - margin }
        return max(0, cols - margin - width)
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
    /// Width of the two *list* overlays. 64 is the width one sentence needs —
    /// the Settings path — and making every overlay that wide put 816 device
    /// pixels of empty highlighted row between a command and its accelerator,
    /// which is the silhouette of a 1995 menu. Width is now a property of the
    /// **kind** of overlay and never of what you have typed, so a panel can be
    /// sized to its own content without resizing under your fingers.
    static let overlayListWidth = 44

    /// Width of §5.7's two status-line pickers. Their longest row is
    /// `javascript` and their whole job is to answer one short question, so at
    /// the list width they were 44 cells of mostly nothing — the same failure
    /// `overlayListWidth` was introduced to fix for the palette, one size down.
    /// Width is a property of the KIND of overlay and never of what you have
    /// typed, so a panel can be sized to its own content without resizing under
    /// your fingers.
    static let overlayPickerWidth = 26

    static func overlayWidth(_ kind: AppModel.Overlay) -> Int {
        switch kind {
        case .peers: return overlayWidth
        case .language, .indent: return overlayPickerWidth
        case .files, .commands: return overlayListWidth
        }
    }

    /// Grid row of result `i`, shared with the click hit-test.
    static func overlayRow(_ i: Int) -> Int { overlayTopRow + 3 + i }
    static func overlayIndex(atRow row: Int) -> Int {
        row < overlayTopRow + 3 ? -1 : row - (overlayTopRow + 3)
    }
    static func overlayCol(cols: Int, _ kind: AppModel.Overlay) -> Int {
        max(0, (cols - overlayWidth(kind)) / 2)
    }

    static func overlay(_ app: AppModel, _ kind: AppModel.Overlay,
                        into w: inout InstanceWriter, now: Double, cols: Int, rows: Int) {
        // The scrim is written at 225/255 rather than something gentler because
        // the blend is in LINEAR light (§5.2): three quarters of coverage there
        // is only about half the perceived brightness, so a scrim tuned by the
        // sRGB number would barely dim anything.
        w.fill(col: 0, row: 0, cols: cols, rows: rows, ink: .scrim, alpha: 225)

        let items = app.overlayItems
        let shown = min(items.count, overlayMaxRows)
        let width = overlayWidth(kind)
        let pcol = overlayCol(cols: cols, kind)
        let panelRows = 3 + max(app.overlayEmptyLines.count, shown) + 1
        w.fill(col: pcol, row: overlayTopRow, cols: width, rows: panelRows, ink: .surface)

        // **A one-device-pixel border on all four sides.** The panel is only
        // 1.18:1 against its own scrim, so without an edge it does not read as
        // a card floating over the document — it reads as the code behind it
        // having gone wrong, because the panel boundary cuts a line of source
        // mid-word and nothing says a boundary is what happened. Four hairlines
        // are ~150 quads in a plane that is already being written, and they are
        // the difference between an occlusion and a rendering fault.
        for i in 0..<width {
            w.put(col: pcol + i, row: overlayTopRow - 1, glyph: GlyphAtlas.dividerHIndex, ink: .edge)
            w.put(col: pcol + i, row: overlayTopRow + panelRows - 1,
                  glyph: GlyphAtlas.dividerHIndex, ink: .edge)
        }
        for r in overlayTopRow..<(overlayTopRow + panelRows) {
            w.put(col: pcol, row: r, glyph: GlyphAtlas.dividerVIndex, ink: .edge)
            w.put(col: pcol + width, row: r, glyph: GlyphAtlas.dividerVIndex, ink: .edge)
        }

        let label: String
        switch kind {
        case .files: label = "open"
        case .peers: label = "who's nearby"
        case .commands: label = "run"
        case .language: label = "language"
        case .indent: label = "indent"
        }
        var c = w.text(label, col: pcol + 2, row: overlayTopRow + 1, ink: .faint) + 1
        c = w.text(app.overlayQuery, col: c, row: overlayTopRow + 1, ink: .fg)
        w.put(col: c, row: overlayTopRow + 1, glyph: GlyphAtlas.caretGlyphIndex, ink: .caret)
        // The separator is `dividerH`, not `rule`: `rule` is two device pixels
        // (it is the placeholder the join code's digits land on, where that
        // weight is right) and two hairline weights in one product is a design
        // system with a leak in it. It sits on the bottom edge of the row under
        // the query — 35 px clear of the query's baseline and 10 px above the
        // first result's cap-top — rather than on the *baseline* of that row,
        // where `rule` put it 8 px above the list and clipped by nothing.
        for i in 0..<width {
            w.put(col: pcol + i, row: overlayTopRow + 2, glyph: GlyphAtlas.dividerHIndex, ink: .edge)
        }

        if items.isEmpty {
            // Paragraph lines do not get air between them: the two lines of a
            // designed empty state are one sentence (PLAN.md §5.2).
            for (i, line) in app.overlayEmptyLines.enumerated() {
                // Clipped to the panel rather than trusted to fit. One of these
                // strings interpolates a folder path, so its length is the
                // user's, not the designer's — and a designed empty state that
                // runs onto the scrim is the exact failure `--dump-scene`
                // caught once already.
                w.text(String(String(line.0.unicodeScalars.prefix(width - 4))),
                       col: pcol + 2, row: overlayRow(i), ink: line.1)
            }
            return
        }
        for i in 0..<shown {
            let r = overlayRow(i)
            if i == app.overlaySelection {
                w.fill(col: pcol + 1, row: r, cols: width - 1, rows: 1, ink: .selection)
            } else if app.hover == .overlayRow(i) {
                w.fill(col: pcol + 1, row: r, cols: width - 1, rows: 1, ink: .hover)
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
            var room = width - (c - pcol) - 2
            if let sc = item.shortcut, !sc.isEmpty {
                let n = sc.unicodeScalars.count
                w.text(sc, col: pcol + width - 2 - n, row: r, ink: .faint)
                room -= n + 2
            } else if i == app.overlaySelection, item.number == nil {
                // **Actionable, for the price of nothing permanent.** The row
                // you are on says what the next keystroke does, and only that
                // row does — so the hint exists exactly while it is true and
                // is gone the instant you arrow off it. Rows that already carry
                // an accelerator (the palette) or a number key (the peer list,
                // §5.1's gesture) have answered the question and keep theirs.
                //
                // The word, not a return glyph: `↩` is not in SF Mono, so it
                // resolves through the cascade to a proportional face and
                // arrives squashed into one cell. Six cells of `faint` is
                // cheaper than a fallback nobody can predict.
                w.text("return", col: pcol + width - 8, row: r, ink: .faint)
                room -= 8
            }
            // Truncation keeps the TAIL of a path — the file's own name is the
            // part you are reading — and says so with a leading ellipsis. It
            // used to drop the head silently, so `src/renderer.rs` in a narrow
            // panel became `enderer.rs`, which is not a shorter name, it is a
            // wrong one.
            let title = item.title
            if title.unicodeScalars.count > room, room > 1 {
                w.put(col: c, row: r, glyph: GlyphCache.shared.glyph(for: "\u{2026}"), ink: .faint)
                w.text(String(String(title.unicodeScalars.suffix(room - 1))), col: c + 1, row: r,
                       ink: i == app.overlaySelection ? .fg : .dim)
            } else {
                w.text(title, col: c, row: r, ink: i == app.overlaySelection ? .fg : .dim)
            }
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
        guard !spans.isEmpty else { return }
        var col = hudStartCol(spans: spans, cols: cols)
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
