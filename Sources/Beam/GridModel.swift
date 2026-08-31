import Foundation

/// Phase-2 text model: a flat monospace grid of ASCII cells, edited through
/// explicit cursors so local and remote peers share one code path. Still the
/// walking skeleton's stand-in for the Phase-1 rope and the Phase-3 CRDT —
/// remote inserts land at the sender's cursor and last writer wins on a cell,
/// which is honest for two people in different regions and nothing more
/// (PLAN.md §5.1, "deliberately not built yet"). 0 = empty cell.
final class GridModel {
    struct Cursor: Equatable {
        var col = 0
        var row = 0
    }

    let cols: Int
    let rows: Int
    private(set) var cells: [UInt8]
    var cursor = Cursor()

    var cursorCol: Int { cursor.col }
    var cursorRow: Int { cursor.row }

    init(cols: Int = 200, rows: Int = 120) {
        self.cols = cols
        self.rows = rows
        cells = [UInt8](repeating: 0, count: cols * rows)
    }

    func typeAscii(_ c: UInt8, at cursor: inout Cursor) {
        guard c >= 32 && c < 127 else { return }
        guard cursor.row >= 0, cursor.row < rows, cursor.col >= 0, cursor.col < cols else { return }
        cells[cursor.row * cols + cursor.col] = c
        cursor.col += 1
        if cursor.col >= cols { newline(at: &cursor) }
    }

    func newline(at cursor: inout Cursor) {
        cursor.col = 0
        cursor.row += 1
        if cursor.row >= rows { cursor.row = 0 }  // wrap; Phase 1 replaces with scrolling
    }

    func backspace(at cursor: inout Cursor) {
        if cursor.col > 0 { cursor.col -= 1 }
        else if cursor.row > 0 { cursor.row -= 1; cursor.col = cols - 1 }
        guard cursor.row >= 0, cursor.row < rows, cursor.col >= 0, cursor.col < cols else { return }
        cells[cursor.row * cols + cursor.col] = 0
    }

    /// Arrow-key movement, clamped to the grid. Selection and scrolling are
    /// deliberately absent — they belong with the Phase-1 rope, not bolted onto
    /// a fixed cell array (PLAN.md §6).
    func move(dx: Int, dy: Int, at cursor: inout Cursor) {
        cursor.col = min(max(0, cursor.col + dx), cols - 1)
        cursor.row = min(max(0, cursor.row + dy), rows - 1)
    }

    // Local-cursor conveniences (the keystroke hot path).
    func typeAscii(_ c: UInt8) { typeAscii(c, at: &cursor) }
    func newline() { newline(at: &cursor) }
    func backspace() { backspace(at: &cursor) }
    func move(dx: Int, dy: Int) { move(dx: dx, dy: dy, at: &cursor) }
}
