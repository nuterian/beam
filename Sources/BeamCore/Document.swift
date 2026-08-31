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

    // MARK: - What is on disk (PLAN.md §5.8)
    //
    // `save()` writes atomically over whatever is there. Atomic means the write
    // cannot be torn; it says nothing about whether the bytes it replaces are
    // the bytes this document was opened from. A `git checkout`, a rebase, a
    // formatter, or the same file open in another editor all replace them
    // silently, and Beam would then overwrite that work with a buffer that
    // never saw it — the one kind of data loss a user cannot undo, because the
    // losing edit is a legitimate save they asked for.
    //
    // Identity is (modification date, size). Not a hash: hashing is O(file) on
    // a path that is checked on every window activation and before every save,
    // and the pair catches every case that matters. A rewrite that preserves
    // both to the nanosecond is not something to design against; a rewrite that
    // preserves neither is what actually happens.

    /// What the file looked like the last time this document and the disk
    /// agreed — set on open and on save, and nowhere else.
    public struct DiskStamp: Equatable {
        public let modified: Date
        public let size: Int
    }
    public private(set) var diskStamp: DiskStamp?

    /// Someone else wrote this file while it had unsaved edits here.
    ///
    /// A **stored flag, not a question asked per frame**: `diskState` is a
    /// `stat`, and the status line is drawn on the keystroke path. It is set by
    /// `AppModel.refreshFromDisk` on window activation — a transition, a few
    /// times a minute — and cleared by whatever resolves the conflict.
    /// Settable from the app layer because `AppModel.refreshFromDisk` is the
    /// one place that decides a conflict exists — the document itself never
    /// polls the disk.
    public var hasDiskConflict = false

    /// Find state, per document (PLAN.md §5.8). Per document rather than per
    /// window for the same reason each tab keeps its own buffer, undo stack and
    /// token cache: switching tabs is a pointer change, and a find that
    /// followed you between files would be answering a question about a
    /// document you are no longer looking at.
    public var find = FindState()

    /// Reads the file's current identity, or nil if it is gone.
    public static func stamp(ofPath p: String) -> DiskStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: p),
              let m = a[.modificationDate] as? Date, let n = a[.size] as? Int else { return nil }
        return DiskStamp(modified: m, size: n)
    }

    /// How the file on disk differs from what this document was opened from.
    public enum DiskState: Equatable {
        case unchanged
        case modified   // someone else wrote it
        case deleted    // it is not there any more
        case untracked  // never saved, or opened before stamps existed
    }

    public var diskState: DiskState {
        guard let p = path, let known = diskStamp else { return .untracked }
        guard let now = Self.stamp(ofPath: p) else { return .deleted }
        return now == known ? .unchanged : .modified
    }

    /// Cells a tab advances to. Real source has tabs in it, and a tab that does
    /// not advance the grid is the same corruption class as the UTF-8 bug.
    ///
    /// Per-document, and settable, because §5.7 put it on the status line and a
    /// status segment that reports a fact you cannot change is a label. The
    /// default is what it has always been.
    public static let defaultTabWidth = 4
    public var tabWidth = Document.defaultTabWidth
    /// Whether this file indents with tabs. **Detected, not assumed** — it is a
    /// property of the file in front of you, and guessing wrong makes every
    /// line you add disagree with every line already there.
    public private(set) var indentsWithTabs = false

    /// What ends a line in this file.
    public enum LineEnding: String {
        case lf = "LF"
        case crlf = "CRLF"
    }
    public private(set) var lineEnding: LineEnding = .lf

    /// The text encoding. Beam reads and writes raw bytes and every path in it
    /// — the lexer, the column arithmetic, the glyph cache — assumes UTF-8, so
    /// this is a statement of what Beam *does* rather than a detected value,
    /// and it is on the status line for exactly that reason: it is the one of
    /// the four that cannot be anything else, and saying so is more useful than
    /// leaving the user to wonder.
    public let encoding = "UTF-8"

    /// Reads the file's format off the top of the buffer.
    ///
    /// **Bounded, because this runs on the open path**, which is budgeted
    /// (`open_1mb_file_to_first_paint_ms`). Indentation and line endings are
    /// consistent within a file or they are not a property of it at all, so a
    /// sample settles the question; walking a megabyte to answer it would put
    /// the whole file inside a budget that exists to keep the first paint fast.
    private static let formatSampleBytes = 16_384

    private func detectFormat() {
        let n = min(buffer.count, Self.formatSampleBytes)
        var tabs = 0, spaces = 0, crlf = 0, lf = 0
        var atLineStart = true
        var i = 0
        while i < n {
            let b = buffer.byte(at: i)
            if b == 0x0A {
                if i > 0, buffer.byte(at: i - 1) == 0x0D { crlf += 1 } else { lf += 1 }
                atLineStart = true
            } else if atLineStart {
                // Only the FIRST character of a line votes. Counting every
                // leading space would let one deeply-indented block outvote the
                // rest of the file.
                if b == 0x09 { tabs += 1 } else if b == 0x20 { spaces += 1 }
                atLineStart = false
            }
            i += 1
        }
        indentsWithTabs = tabs > spaces
        lineEnding = crlf > lf ? .crlf : .lf
    }

    /// Sets what an indent is in this document. Chosen from the status line's
    /// picker (PLAN.md §5.7); it changes what Tab inserts and how wide an
    /// existing tab renders, and nothing else — no file is reformatted behind
    /// your back on the strength of a status-bar click.
    public func setIndent(tabs: Bool, width: Int) {
        indentsWithTabs = tabs
        tabWidth = max(1, width)
    }

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
        // Stamped from the file we just read, so a write that lands between
        // the read and the stamp shows up as a difference rather than being
        // adopted as ours.
        diskStamp = Self.stamp(ofPath: p)
        hasDiskConflict = false
        isModified = false
        ioError = nil
        caret = 0
        anchor = nil
        desiredColumn = nil
        scrollPx = 0
        undo.clear()
        highlighter.reset(language: .forPath(p), buffer: buffer)
        detectFormat()
        return true
    }

    /// Save, refusing to overwrite somebody else's work.
    ///
    /// `force` is what the user's own confirmation grants, and it is the only
    /// way past the check — there is no path where Beam decides on its own
    /// that the other write did not matter.
    @discardableResult
    public func save(force: Bool = false) -> Bool {
        guard let p = path else { ioError = "no path — this document has never been saved"; return false }
        if !force, diskState == .modified {
            ioError = "\((p as NSString).lastPathComponent) changed on disk"
            return false
        }
        let data = Data(buffer.bytes(in: 0..<buffer.count))
        do {
            try data.write(to: URL(fileURLWithPath: p), options: .atomic)
            isModified = false
            ioError = nil
            // Re-stamp from the file, never from what we believe we wrote: the
            // modification date is the filesystem's to decide.
            diskStamp = Self.stamp(ofPath: p)
            hasDiskConflict = false
            undo.breakCoalescing()
            return true
        } catch {
            ioError = "cannot write \((p as NSString).lastPathComponent)"
            return false
        }
    }

    /// The answer that cannot lose anything: write this buffer to a new file
    /// beside the original and leave the original as whoever else wrote it.
    ///
    /// Every other resolution throws one of the two versions away. This one is
    /// offered first for that reason — a conflict is a moment when the person
    /// does not yet know which version they want, and an editor's job at that
    /// moment is to stop being the reason a choice is irreversible.
    ///
    /// The document *keeps its original path*: the copy is a rescue, not a
    /// rename, and silently repointing the tab at a file the user never named
    /// would leave them editing something they did not open.
    @discardableResult
    public func saveCopyBesideOriginal() -> String? {
        guard let p = path else { return nil }
        let ns = p as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        // A counter, because the second conflict on the same file must not
        // overwrite the rescue from the first one.
        for n in 1...999 {
            let suffix = n == 1 ? "conflict" : "conflict-\(n)"
            let candidate = ext.isEmpty ? "\(base).\(suffix)" : "\(base).\(suffix).\(ext)"
            guard !FileManager.default.fileExists(atPath: candidate) else { continue }
            let data = Data(buffer.bytes(in: 0..<buffer.count))
            guard (try? data.write(to: URL(fileURLWithPath: candidate), options: .atomic)) != nil else {
                ioError = "cannot write \((candidate as NSString).lastPathComponent)"
                return nil
            }
            ioError = "saved a copy as \((candidate as NSString).lastPathComponent)"
            return candidate
        }
        ioError = "too many conflict copies beside \(ns.lastPathComponent)"
        return nil
    }

    /// Re-read the file from disk, discarding this document's edits. The other
    /// half of the external-modification answer: keep mine, or take theirs.
    @discardableResult
    public func revert() -> Bool {
        guard let p = path else { return false }
        return open(path: p)
    }

    /// Seeds a document without touching the disk — the seam `--dump-scene`
    /// and `--screenshot` use so both tools show the shipping layout on a
    /// machine with no file and no GPU (PLAN.md §5.2).
    public func debugLoad(text: String, name: String) {
        buffer = TextBuffer(bytes: Array(text.utf8))
        path = name
        // No disk behind a seeded document, so no stamp: `diskState` reports
        // `.untracked` and the guards stay out of the way of the tools.
        diskStamp = nil
        isModified = false
        caret = 0
        anchor = nil
        undo.clear()
        highlighter.reset(language: .forPath(name), buffer: buffer)
        detectFormat()
    }

    /// Seeds the modified flag for the visual tools, with no edit behind it —
    /// `--dump-scene` and `--screenshot` need to show a document that has
    /// unsaved changes without inventing an edit that would move the caret and
    /// the line index out from under the seeded layout.
    public func debugMarkModified() { isModified = true }

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
        // **An edit moves every offset after it**, so the match list is stale
        // the instant the buffer changes. Re-scanning here would put find on
        // the typing path for everyone, including the people not searching; the
        // honest cheap answer is to re-scan only while find is actually open,
        // which is a state the user chose and a cost they can see.
        if !find.isEmpty { find.rescan(buffer, near: caret) }
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

    /// ⌥⌫ and ⌥⌦ — delete a whole word. A selection wins, as everywhere else.
    @discardableResult
    public func deleteWordBackward() -> Edit? {
        if selection != nil { return deleteBackward() }
        let start = wordStart(before: caret)
        guard start < caret else { return nil }
        undo.breakCoalescing()
        return perform(Edit(offset: start, removed: buffer.bytes(in: start..<caret), inserted: []))
    }

    @discardableResult
    public func deleteWordForward() -> Edit? {
        if selection != nil { return deleteForward() }
        let end = wordEnd(after: caret)
        guard end > caret else { return nil }
        undo.breakCoalescing()
        return perform(Edit(offset: caret, removed: buffer.bytes(in: caret..<end), inserted: []))
    }

    /// ⌃K — kill to end of line, and ⌃U — to the start. Both are standard macOS
    /// text bindings that every Cocoa text surface has had for thirty years.
    @discardableResult
    public func deleteToLineEnd() -> Edit? {
        let r = buffer.lineRange(buffer.line(ofOffset: caret))
        // On an already-empty tail, kill the newline itself — otherwise ⌃K on a
        // blank line does nothing, which is not what it does anywhere else.
        let end = caret < r.upperBound ? r.upperBound : min(buffer.count, r.upperBound + 1)
        guard end > caret else { return nil }
        undo.breakCoalescing()
        return perform(Edit(offset: caret, removed: buffer.bytes(in: caret..<end), inserted: []))
    }

    @discardableResult
    public func deleteToLineStart() -> Edit? {
        let start = buffer.lineRange(buffer.line(ofOffset: caret)).lowerBound
        guard start < caret else { return nil }
        undo.breakCoalescing()
        return perform(Edit(offset: start, removed: buffer.bytes(in: start..<caret), inserted: []))
    }

    /// Selects the word under the caret — double-click, and ⌥⇧-arrow's anchor.
    public func selectWord() {
        let lo = wordStart(before: wordEnd(after: caret))
        let hi = wordEnd(after: lo)
        guard hi > lo else { return }
        anchor = lo
        caret = hi
        undo.breakCoalescing()
    }

    public func selectLine() {
        let r = buffer.lineRange(buffer.line(ofOffset: caret))
        anchor = r.lowerBound
        caret = min(buffer.count, r.upperBound + 1)
        undo.breakCoalescing()
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
            if b == 0x09 { col += tabWidth - (col % tabWidth) } else if b & 0xC0 != 0x80 { col += 1 }
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
            let width = b == 0x09 ? tabWidth - (col % tabWidth) : 1
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

    public enum Motion {
        case left, right, up, down
        case wordLeft, wordRight
        case lineStart, lineEnd, docStart, docEnd, pageUp, pageDown
    }

    /// Word characters, for ⌥-arrow movement and ⌥-delete. Bytes >= 0x80 count
    /// as word characters so a word with an accent in it is one word.
    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39) || b == 0x5F || b >= 0x80
    }

    /// Start of the word at or before an offset — the macOS convention: skip
    /// any run of non-word bytes first, then the word itself.
    public func wordStart(before offset: Int) -> Int {
        var i = min(max(0, offset), buffer.count)
        while i > 0, !Self.isWordByte(buffer.byte(at: i - 1)) { i -= 1 }
        while i > 0, Self.isWordByte(buffer.byte(at: i - 1)) { i -= 1 }
        return i
    }

    public func wordEnd(after offset: Int) -> Int {
        var i = min(max(0, offset), buffer.count)
        while i < buffer.count, !Self.isWordByte(buffer.byte(at: i)) { i += 1 }
        while i < buffer.count, Self.isWordByte(buffer.byte(at: i)) { i += 1 }
        return i
    }

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
        case .wordLeft:
            if !extend, let sel = selection { caret = sel.lowerBound; break }
            caret = wordStart(before: caret)
            desiredColumn = nil
        case .wordRight:
            if !extend, let sel = selection { caret = sel.upperBound; break }
            caret = wordEnd(after: caret)
            desiredColumn = nil
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
