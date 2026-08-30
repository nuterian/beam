import Foundation

/// Phase-0 text model: a flat monospace grid of ASCII cells. This is the
/// walking skeleton's stand-in for the Phase-1 rope; it exists to be typed
/// into and measured. 0 = empty cell.
final class GridModel {
    let cols: Int
    let rows: Int
    private(set) var cells: [UInt8]
    private(set) var cursorCol = 0
    private(set) var cursorRow = 0

    init(cols: Int = 200, rows: Int = 120) {
        self.cols = cols
        self.rows = rows
        cells = [UInt8](repeating: 0, count: cols * rows)
    }

    func typeAscii(_ c: UInt8) {
        guard c >= 32 && c < 127 else { return }
        cells[cursorRow * cols + cursorCol] = c
        cursorCol += 1
        if cursorCol >= cols { newline() }
    }

    func newline() {
        cursorCol = 0
        cursorRow += 1
        if cursorRow >= rows { cursorRow = 0 }  // wrap; Phase 1 replaces with scrolling
    }

    func backspace() {
        if cursorCol > 0 { cursorCol -= 1 }
        else if cursorRow > 0 { cursorRow -= 1; cursorCol = cols - 1 }
        cells[cursorRow * cols + cursorCol] = 0
    }
}
