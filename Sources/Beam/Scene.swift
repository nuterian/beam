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

    /// Draws ASCII. Non-printables are skipped rather than boxed: Beam has one
    /// font and one cell size, and a tofu box would be the first lie the grid told.
    @discardableResult
    mutating func text(_ s: String, col: Int, row: Int, ink: Renderer.Ink, alpha: UInt8 = 255) -> Int {
        var c = col
        for b in s.utf8 {
            if b >= 32 && b < 127 { put(col: c, row: row, glyph: UInt16(b - 32), ink: ink, alpha: alpha) }
            c += 1
        }
        return c
    }
}

/// Every pixel Beam draws. Three surfaces, one atlas, one draw call.
///
/// **The layout grid** (PLAN.md §5.2, composition). Beam has one alignment
/// grid and every surface obeys it, so the app reads as one designed page
/// rather than three screens that happen to share a font:
///
/// ```
///   col:  0        6                                             cols-6
///         |        |                                                  |
///  row 0  |  (traffic lights live in this band — nothing is drawn here)
///  row 3  |        beam
///  row 6  |        you    studio-mbp
///  row 9  |        1  ▪   marlowe-air
///  row 11 |        2  ▪   atlas-mini            <- peers every OTHER row
///   ...   |
///  last   |        press a number, or click             p50 8.4  p99 12.1 ms
/// ```
///
/// Two spacing rules do most of the work. **List items get air** — peers sit
/// two rows apart, so the roster reads as a list of machines rather than as a
/// code listing. **Paragraph lines do not** — the two lines of an empty or
/// denied state are one sentence and stay adjacent. And the page is anchored
/// at both ends: a block at the top, a single quiet line along the bottom.
enum Scene {
    /// Left inset, in cells. 6 cells is 63 pt at 2x, which is exactly past the
    /// right edge of the traffic lights — so the chrome sits in the margin the
    /// design already reserved instead of on top of anything.
    static let margin = 6
    /// First row anything is drawn on. Rows 0–2 are the band the traffic lights
    /// occupy; leaving them empty is what makes a title-less window look
    /// deliberate rather than broken.
    static let topRow = 3
    /// Your own identity, three rows under the mark.
    static let identityRow = topRow + 3
    /// Grid row of the first peer. Shared with GridView's click hit-test —
    /// clicking a peer and pressing its number must select the same peer.
    static let firstPeerRow = topRow + 6
    /// Peers every other row. The blank row between them is the click target's
    /// second half, so the rhythm costs nothing in pointing accuracy.
    static let peerRowStride = 2

    /// Columns inside a peer row. `nameCol` is shared with the identity row, so
    /// your machine and everyone else's line up in one column.
    static let numberCol = margin
    static let chipCol = margin + 3
    static let nameCol = margin + 6

    static func peerRow(_ i: Int) -> Int { firstPeerRow + i * peerRowStride }

    /// Inverse of `peerRow`, for the click hit-test. Integer division means a
    /// peer's row *and* the blank under it both select it — a two-row target.
    static func peerIndex(atRow row: Int) -> Int {
        (row - firstPeerRow) / peerRowStride
    }

    /// The editor's text origin. Same left margin as every other surface; two
    /// rows down so the first line of code is not wedged against the window's
    /// top edge beside the close button.
    static let editorCol = margin
    static let editorRow = 2

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

    // MARK: - Surfaces

    /// The launch screen IS the peer list. Alone on the network is a designed
    /// state with its own words, not a blank area where a list would be.
    static func roster(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                       cols: Int, rows: Int) {
        w.text("beam", col: margin, row: topRow, ink: .accent)
        w.text("you", col: margin, row: identityRow, ink: .faint)
        w.text(Peer.display(of: app.localName), col: nameCol, row: identityRow, ink: .dim)

        let row = firstPeerRow
        switch app.presence {
        case .localNetworkDenied:
            w.text("local network access is off.", col: margin, row: row, ink: .red)
            w.text("system settings > privacy & security > local network > beam",
                   col: margin, row: row + 1, ink: .faint)
            return
        case .advertiseFailed:
            w.text("cannot advertise on this network.", col: margin, row: row, ink: .red)
            w.text("beam can still see peers, but they cannot see you.",
                   col: margin, row: row + 1, ink: .faint)
            return
        case .searching, .ok:
            break
        }

        if app.peers.isEmpty {
            w.text("no one else here yet.", col: margin, row: row, ink: .dim)
            w.text("beam is listening. open beam on another mac.",
                   col: margin, row: row + 1, ink: .faint)
            return
        }

        for (i, peer) in app.peers.prefix(9).enumerated() {
            let a = AppModel.alpha(since: peer.appearedAt, now: now)
            let r = peerRow(i)
            w.text("\(i + 1)", col: numberCol, row: r, ink: .faint, alpha: a)
            w.put(col: chipCol, row: r, glyph: GlyphAtlas.chipGlyphIndex,
                  ink: .peer(peer.inkIndex), alpha: a)
            w.text(peer.display, col: nameCol, row: r, ink: .fg, alpha: a)
        }
        // Bottom-left, on the same line the HUD uses on the right: the page is
        // anchored at both ends instead of trailing off under the last peer.
        w.text("press a number, or click", col: margin, row: max(0, rows - 1), ink: .faint)
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

    /// The editor: the grid, your block cursor, and the peer's caret with their
    /// name beside it in their colour.
    static func editor(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                       cols: Int, rows: Int) {
        let model = app.grid
        // The editor sits on the same margin as every other surface, so the
        // whole app is one page. Its text area is what is left over.
        let visibleRows = min(model.rows, max(0, rows - editorRow - 1))
        let visibleCols = min(model.cols, max(0, cols - editorCol - margin))
        model.cells.withUnsafeBufferPointer { cells in
            for row in 0..<visibleRows {
                let base = row * model.cols
                for col in 0..<visibleCols {
                    let c = cells[base + col]
                    if c < 32 || c >= 127 { continue }
                    w.put(col: editorCol + col, row: editorRow + row, glyph: UInt16(c - 32), ink: .fg)
                }
            }
        }
        // Your cursor: a solid block, and it does not blink. See PLAN.md §5.1.
        if model.cursorRow < visibleRows && model.cursorCol < visibleCols {
            w.put(col: editorCol + model.cursorCol, row: editorRow + model.cursorRow,
                  glyph: GlyphAtlas.blockGlyphIndex, ink: .dim)
        }
        // Their cursor: a thin bar in their colour, with their name trailing it
        // in their colour, fading in.
        //
        // The name goes to the RIGHT of the caret on the SAME row, and only
        // where the row is actually empty. Floating it above the caret — the
        // usual editor treatment — put a permanent label on top of the line
        // above, which on a flat grid with no chrome behind it is just
        // unreadable code. Trailing it works because a typing caret sits at the
        // end of its text; when it doesn't, the coloured caret alone says
        // everything, so we draw nothing rather than cover a character.
        if let r = app.remote, r.cursor.row < visibleRows, r.cursor.col < visibleCols {
            let ink = Renderer.Ink.peer(r.inkIndex)
            w.put(col: editorCol + r.cursor.col, row: editorRow + r.cursor.row,
                  glyph: GlyphAtlas.barGlyphIndex, ink: ink)
            let labelCol = r.cursor.col + 2
            if labelCol + r.name.utf8.count <= visibleCols,
               isRowClear(model, row: r.cursor.row, from: labelCol, count: r.name.utf8.count) {
                w.text(r.name, col: editorCol + labelCol, row: editorRow + r.cursor.row, ink: ink,
                       alpha: AppModel.alpha(since: r.since, now: now))
            }
        }
    }

    /// Whether a run of cells is empty, so a label can sit there without
    /// covering anything a person wrote.
    private static func isRowClear(_ model: GridModel, row: Int, from col: Int, count: Int) -> Bool {
        guard row >= 0, row < model.rows else { return false }
        let base = row * model.cols
        for c in col..<(col + count) {
            guard c >= 0, c < model.cols else { return false }
            if model.cells[base + c] != 0 { return false }
        }
        return true
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
        /// HUD is drawn from the same atlas as everything else, so a peer's
        /// colour can appear inline without a character to stand in for it.
        let glyph: UInt16?

        var width: Int { glyph != nil ? 1 : text.utf8.count }

        init(_ text: String, _ ink: Renderer.Ink) {
            self.text = text
            self.ink = ink
            self.glyph = nil
        }
        init(glyph: UInt16, _ ink: Renderer.Ink) {
            self.text = ""
            self.ink = ink
            self.glyph = glyph
        }
    }

    /// HUD, bottom-right, inset by the same margin as the left edge: live
    /// latency against the same budgets.json CI reads, plus each peer's live
    /// RTT. We publish our latency because we are the only editor that can
    /// afford to.
    static func hud(into w: inout InstanceWriter, spans: [Span], cols: Int, rows: Int) {
        var width = 0
        for s in spans { width += s.width }
        guard width > 0 else { return }
        var col = max(0, cols - margin - width)
        let row = max(0, rows - 1)
        for s in spans {
            if let g = s.glyph {
                w.put(col: col, row: row, glyph: g, ink: s.ink)
                col += 1
            } else {
                col = w.text(s.text, col: col, row: row, ink: s.ink)
            }
        }
    }
}
