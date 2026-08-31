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
enum Scene {
    /// Left margin, in cells. Generous on purpose: the emptiness is the design.
    static let margin = 4
    /// Grid row of the first peer. Shared with GridView's click hit-test —
    /// clicking a peer and pressing its number must select the same peer.
    static let firstPeerRow = 6

    /// 3x5 block digits for the join code, drawn from the solid-block glyph at
    /// two cells per pixel (cells are about twice as tall as wide, so a
    /// two-cell pixel is square). Readable across a desk, which is the entire
    /// requirement — a code nobody bothers to compare authenticates nothing.
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
    private static let digitCellWidth = 8   // 3 pixels x 2 cells + 2 cells of gap
    static let digitHeight = 5

    static func digit(_ d: Int, into w: inout InstanceWriter, col: Int, row: Int,
                      ink: Renderer.Ink, alpha: UInt8) {
        guard d >= 0, d < 10 else { return }
        let bits = digitRows[d]
        for r in 0..<digitHeight {
            for c in 0..<3 where bits[r] & (0b100 >> c) != 0 {
                w.put(col: col + c * 2, row: row + r, glyph: GlyphAtlas.blockGlyphIndex, ink: ink, alpha: alpha)
                w.put(col: col + c * 2 + 1, row: row + r, glyph: GlyphAtlas.blockGlyphIndex, ink: ink, alpha: alpha)
            }
        }
    }

    // MARK: - Surfaces

    /// The launch screen IS the peer list. Alone on the network is a designed
    /// state with its own words, not a blank area where a list would be.
    static func roster(_ app: AppModel, into w: inout InstanceWriter, now: Double, cols: Int) {
        w.text("beam", col: margin, row: 2, ink: .accent)
        w.text("you", col: margin, row: 4, ink: .faint)
        w.text(Peer.display(of: app.localName), col: margin + 7, row: 4, ink: .dim)

        var row = firstPeerRow
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
            w.text("\(i + 1)", col: margin, row: row, ink: .faint, alpha: a)
            w.put(col: margin + 3, row: row, glyph: GlyphAtlas.dotGlyphIndex,
                  ink: .peer(peer.inkIndex), alpha: a)
            // Same column as your own name above it: the roster reads as one
            // list of machines, with you at the top of it.
            w.text(peer.display, col: margin + 7, row: row, ink: .fg, alpha: a)
            row += 1
        }
        w.text("press a number, or click", col: margin, row: row + 1, ink: .faint)
    }

    /// Six digits, both screens, one keypress each. The gesture already landed
    /// — this surface is drawn before any network byte moves, which is why the
    /// connection feels instant and why the dashes become digits rather than
    /// the screen appearing only once the handshake lands.
    static func pairing(_ app: AppModel, sas: String, into w: inout InstanceWriter, now: Double) {
        w.text("beam", col: margin, row: 2, ink: .accent)
        let ink = Renderer.Ink.peer(app.joiningInk)
        w.text(app.joiningName, col: margin, row: 4, ink: ink)

        let codeRow = 6
        for i in 0..<6 {
            let col = margin + i * digitCellWidth
            if sas.count == 6, let d = sas[sas.index(sas.startIndex, offsetBy: i)].wholeNumberValue {
                digit(d, into: &w, col: col, row: codeRow, ink: .accent, alpha: 255)
            } else {
                // Waiting on the handshake: a dash where each digit will land.
                for c in 0..<6 {
                    w.put(col: col + c, row: codeRow + 2, glyph: GlyphAtlas.ruleGlyphIndex, ink: .faint)
                }
            }
        }

        let footRow = codeRow + digitHeight + 2
        if sas.isEmpty {
            w.text("connecting...", col: margin, row: footRow, ink: .faint)
        } else if app.isHost {
            w.text("same code on both screens?", col: margin, row: footRow, ink: .dim)
            w.text("return to connect   esc to cancel", col: margin, row: footRow + 1, ink: .faint)
        } else {
            w.text("same code on both screens?", col: margin, row: footRow, ink: .dim)
            w.text("waiting for \(app.joiningName)   esc to cancel",
                   col: margin, row: footRow + 1, ink: .faint)
        }
    }

    /// The editor: the grid, your block cursor, and the peer's caret with their
    /// name beside it in their colour.
    static func editor(_ app: AppModel, into w: inout InstanceWriter, now: Double,
                       cols: Int, rows: Int) {
        let model = app.grid
        let visibleRows = min(model.rows, rows)
        let visibleCols = min(model.cols, cols)
        model.cells.withUnsafeBufferPointer { cells in
            for row in 0..<visibleRows {
                let base = row * model.cols
                for col in 0..<visibleCols {
                    let c = cells[base + col]
                    if c < 32 || c >= 127 { continue }
                    w.put(col: col, row: row, glyph: UInt16(c - 32), ink: .fg)
                }
            }
        }
        // Your cursor: a solid block, and it does not blink. See PLAN.md §5.1.
        if model.cursorRow < visibleRows && model.cursorCol < visibleCols {
            w.put(col: model.cursorCol, row: model.cursorRow,
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
            w.put(col: r.cursor.col, row: r.cursor.row, glyph: GlyphAtlas.barGlyphIndex, ink: ink)
            let labelCol = r.cursor.col + 2
            if labelCol + r.name.utf8.count <= visibleCols,
               isRowClear(model, row: r.cursor.row, from: labelCol, count: r.name.utf8.count) {
                w.text(r.name, col: labelCol, row: r.cursor.row, ink: ink,
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

    /// HUD, bottom-right: live latency against the same budgets.json CI reads,
    /// plus each peer's live RTT. We publish our latency because we are the
    /// only editor that can afford to.
    static func hud(into w: inout InstanceWriter, text: String, ink: Renderer.Ink,
                    cols: Int, rows: Int) {
        guard !text.isEmpty else { return }
        w.text(text, col: max(0, cols - text.utf8.count), row: max(0, rows - 1), ink: ink)
    }
}
