import Foundation

/// One open file: bytes, caret, selection, scroll, undo, syntax.
///
/// Everything that changes the text goes through `perform(_:)`, which applies
/// the edit, records it for undo, invalidates exactly the lines the highlighter
/// needs and returns the `Edit` so the caller can put it on the wire. Local
/// keystrokes and remote ops take the identical path, which is what will make
/// Phase 3 a substitution rather than a second implementation (PLAN.md §5.3).
public final class Document {
    public private(set) var buffer: TextBuffer
    public let undo = UndoStack()
    public let highlighter = Highlighter()

    /// Caret, as a logical byte offset. One caret; multiple carets are not a
    /// Phase-1 feature and pretending otherwise in the model would be
    /// speculative structure (PLAN.md §1).
    public var caret = 0
    /// The other end of the selection, or nil when there is none.
    public var anchor: Int?
    /// Remembered cell column for vertical movement, so ↓↓↑ returns you to the
    /// column you started in rather than to the shortest line you passed.
    public var desiredColumn: Int?

    /// Vertical scroll in **device pixels**, not lines. Pixel-quantized
    /// scrolling is the sharpest TUI/GUI decision in §5.3: the document plane's
    /// origin carries `scrollPx % cellHeight` so text moves continuously while
    /// every glyph still lands on a whole device pixel.
    public var scrollPx = 0
    /// Horizontal scroll, in device pixels, quantized to whole CELLS — a
    /// monospace grid has no sub-cell horizontal position to be at, and lines
    /// do not wrap in Phase 1 (a named gap, not an oversight: soft wrap changes
    /// what a "row" is for the caret, the click map and the selection all at
    /// once, and it is not this phase).
    public var scrollXPx = 0

    public private(set) var path: String?
    public private(set) var isModified = false
    /// Set when the last open or save failed, so the status line can say so
    /// instead of the document silently being the wrong thing.
    public private(set) var ioError: String?

    /// Cells a tab advances to. Real source has tabs in it, and a tab that does
    /// not advance the grid is the same corruption class as the UTF-8 bug.
    public static let tabWidth = 4

    public init() {
        buffer = TextBuffer()
        highlighter.reset(language: .plain, buffer: buffer)
    }

    public var displayName: String {
        guard let path else { return "untitled" }
        return (path as NSString).lastPathComponent
    }

    public var selection: Range<Int>? {
        guard let a = anchor, a != caret else { return nil }
        return min(a, caret)..<max(a, caret)
    }

    // MARK: - Files

    /// Deliberate-slowdown hook for `L2.open_1mb_file_to_first_paint_ms`.
    static let openSabotageMs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_OPEN_DELAY_MS"] ?? "") ?? 0

    @discardableResult
    public func open(path p: String) -> Bool {
        if Self.openSabotageMs > 0 { usleep(UInt32(Self.openSabotageMs) * 1000) }
        guard let data = FileManager.default.contents(atPath: p) else {
            ioError = "cannot read \((p as NSString).lastPathComponent)"
            return false
        }
        buffer = TextBuffer(bytes: [UInt8](data))
        path = p
        isModified = false
        ioError = nil
        caret = 0
        anchor = nil
        desiredColumn = nil
        scrollPx = 0
        undo.clear()
        highlighter.reset(language: .forPath(p), buffer: buffer)
        return true
    }

    @discardableResult
    public func save() -> Bool {
        guard let p = path else { ioError = "no path — this document has never been saved"; return false }
        let data = Data(buffer.bytes(in: 0..<buffer.count))
        do {
            try data.write(to: URL(fileURLWithPath: p), options: .atomic)
            isModified = false
            ioError = nil
            undo.breakCoalescing()
            return true
        } catch {
            ioError = "cannot write \((p as NSString).lastPathComponent)"
            return false
        }
    }

    /// Seeds a document without touching the disk — the seam `--dump-scene`
    /// and `--screenshot` use so both tools show the shipping layout on a
    /// machine with no file and no GPU (PLAN.md §5.2).
    public func debugLoad(text: String, name: String) {
        buffer = TextBuffer(bytes: Array(text.utf8))
        path = name
        isModified = false
        caret = 0
        anchor = nil
        undo.clear()
        highlighter.reset(language: .forPath(name), buffer: buffer)
    }

    // MARK: - Editing

    /// The single funnel. Returns the edit that was applied.
    @discardableResult
    public func perform(_ edit: Edit, recordUndo: Bool = true) -> Edit {
        let before = caret
        let line = buffer.line(ofOffset: edit.offset)
        let removedLines = edit.removed.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let addedLines = edit.inserted.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        buffer.apply(edit)
        caret = edit.offset + edit.inserted.count
        anchor = nil
        desiredColumn = nil
        isModified = true
        if recordUndo { undo.record(edit, caretBefore: before, caretAfter: caret) }
        highlighter.invalidate(line: line, buffer: buffer, linesAdded: addedLines - removedLines)
        return edit
    }

    /// Inserts text at the caret, replacing the selection if there is one.
    @discardableResult
    public func insert(_ bytes: [UInt8]) -> Edit {
        if let sel = selection {
            let removed = buffer.bytes(in: sel)
            undo.breakCoalescing()
            return perform(Edit(offset: sel.lowerBound, removed: removed, inserted: bytes))
        }
        return perform(Edit(offset: caret, removed: [], inserted: bytes))
    }

    /// Backspace. Deletes the selection if there is one, otherwise one whole
    /// **scalar** — never one byte, or a multi-byte character would be left as
    /// a half-character the decoder renders as a replacement box.
    @discardableResult
    public func deleteBackward() -> Edit? {
        if let sel = selection {
            undo.breakCoalescing()
            return perform(Edit(offset: sel.lowerBound, removed: buffer.bytes(in: sel), inserted: []))
        }
        guard caret > 0 else { return nil }
        var start = caret - 1
        while start > 0, buffer.byte(at: start) & 0xC0 == 0x80 { start -= 1 }
        return perform(Edit(offset: start, removed: buffer.bytes(in: start..<caret), inserted: []))
    }

    @discardableResult
    public func deleteForward() -> Edit? {
        if let sel = selection {
            undo.breakCoalescing()
            return perform(Edit(offset: sel.lowerBound, removed: buffer.bytes(in: sel), inserted: []))
        }
        guard caret < buffer.count else { return nil }
        var end = caret + 1
        while end < buffer.count, buffer.byte(at: end) & 0xC0 == 0x80 { end += 1 }
        return perform(Edit(offset: caret, removed: buffer.bytes(in: caret..<end), inserted: []))
    }

    public func applyUndo() -> Bool {
        guard let step = undo.undo() else { return false }
        perform(step.edit.inverse, recordUndo: false)
        caret = step.caretBefore
        return true
    }

    public func applyRedo() -> Bool {
        guard let step = undo.redo() else { return false }
        perform(step.edit, recordUndo: false)
        caret = step.caretAfter
        return true
    }

    // MARK: - Columns (UTF-8 and tabs)

    /// Cell column of an offset on its own line. Walks the line, because a
    /// column is a *rendering* fact — a tab is four cells, a multi-byte scalar
    /// is one, and neither is derivable from the byte offset alone.
    public func cellColumn(ofOffset offset: Int) -> Int {
        let line = buffer.line(ofOffset: offset)
        let r = buffer.lineRange(line)
        var col = 0
        var i = r.lowerBound
        while i < min(offset, r.upperBound) {
            let b = buffer.byte(at: i)
            if b == 0x09 { col += Self.tabWidth - (col % Self.tabWidth) } else if b & 0xC0 != 0x80 { col += 1 }
            i += 1
        }
        return col
    }

    /// Inverse: the offset nearest a cell column on a line. Clicking past the
    /// end of a line puts the caret at the end of it, which is what every
    /// editor does and what makes clicking in the empty right half feel right.
    public func offset(line: Int, cellColumn target: Int) -> Int {
        let r = buffer.lineRange(min(max(0, line), buffer.lineCount - 1))
        var col = 0
        var i = r.lowerBound
        while i < r.upperBound {
            let b = buffer.byte(at: i)
            let width = b == 0x09 ? Self.tabWidth - (col % Self.tabWidth) : 1
            if b & 0xC0 != 0x80 {
                if col + width > target { return i }
                col += width
            }
            i += 1
        }
        return r.upperBound
    }

    /// Cell width of a whole line — what the horizontal extent of a selection
    /// or a scrollbar has to be measured in.
    public func cellWidth(ofLine line: Int) -> Int {
        cellColumn(ofOffset: buffer.lineRange(line).upperBound)
    }

    // MARK: - Movement

    public enum Motion { case left, right, up, down, lineStart, lineEnd, docStart, docEnd, pageUp, pageDown }

    /// Moves (or extends, when `extend`) the caret. `pageRows` is the viewport
    /// height the view knows and the model does not.
    public func move(_ motion: Motion, extend: Bool, pageRows: Int = 20) {
        if extend, anchor == nil { anchor = caret }
        if !extend { anchor = nil }
        let (line, _) = buffer.position(ofOffset: caret)
        switch motion {
        case .left:
            if !extend, let sel = selection { caret = sel.lowerBound; break }
            var i = caret - 1
            while i > 0, buffer.byte(at: i) & 0xC0 == 0x80 { i -= 1 }
            caret = max(0, i)
            desiredColumn = nil
        case .right:
            if !extend, let sel = selection { caret = sel.upperBound; break }
            var i = min(buffer.count, caret + 1)
            while i < buffer.count, buffer.byte(at: i) & 0xC0 == 0x80 { i += 1 }
            caret = i
            desiredColumn = nil
        case .up, .down:
            let target = desiredColumn ?? cellColumn(ofOffset: caret)
            let next = motion == .up ? line - 1 : line + 1
            guard next >= 0, next < buffer.lineCount else {
                caret = motion == .up ? 0 : buffer.count
                return
            }
            caret = offset(line: next, cellColumn: target)
            desiredColumn = target
            return
        case .pageUp, .pageDown:
            let target = desiredColumn ?? cellColumn(ofOffset: caret)
            let next = min(max(0, line + (motion == .pageUp ? -pageRows : pageRows)), buffer.lineCount - 1)
            caret = offset(line: next, cellColumn: target)
            desiredColumn = target
            return
        case .lineStart: caret = buffer.lineRange(line).lowerBound; desiredColumn = nil
        case .lineEnd:   caret = buffer.lineRange(line).upperBound; desiredColumn = nil
        case .docStart:  caret = 0; desiredColumn = nil
        case .docEnd:    caret = buffer.count; desiredColumn = nil
        }
        undo.breakCoalescing()
    }

    public func selectAll() {
        anchor = 0
        caret = buffer.count
        desiredColumn = nil
        undo.breakCoalescing()
    }

    public func placeCaret(at offset: Int, extend: Bool) {
        if extend {
            if anchor == nil { anchor = caret }
        } else {
            anchor = nil
        }
        caret = min(max(0, offset), buffer.count)
        desiredColumn = nil
        undo.breakCoalescing()
    }

    // MARK: - Scrolling

    /// Clamps the scroll to the document, leaving one screen minus two lines of
    /// overscroll at the bottom so the last line is reachable without being
    /// pinned against the status line.
    public func clampScroll(cellHeightPx: Int, viewportRows: Int) {
        let maxLine = max(0, buffer.lineCount - max(1, viewportRows - 2))
        scrollPx = min(max(0, scrollPx), maxLine * cellHeightPx)
    }

    /// Scrolls so the caret is on screen, by the smallest movement that does
    /// it. Called after any caret change, never after a wheel event — scrolling
    /// away from the caret is a thing users do on purpose.
    public func revealCaret(cellWidthPx: Int, cellHeightPx: Int,
                            viewportRows: Int, viewportCols: Int) {
        let line = buffer.line(ofOffset: caret)
        let top = scrollPx / cellHeightPx
        let bottom = top + max(1, viewportRows) - 1
        if line < top { scrollPx = line * cellHeightPx }
        else if line >= bottom { scrollPx = (line - max(1, viewportRows) + 2) * cellHeightPx }
        scrollPx = max(0, scrollPx)

        let col = cellColumn(ofOffset: caret)
        let first = scrollXPx / cellWidthPx
        if col < first { scrollXPx = col * cellWidthPx }
        else if col >= first + max(1, viewportCols) - 1 {
            scrollXPx = (col - max(1, viewportCols) + 2) * cellWidthPx
        }
        scrollXPx = max(0, scrollXPx)
    }
}
